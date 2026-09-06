'use strict';

process.env.AWS_SDK_JS_SUPPRESS_MAINTENANCE_MODE_MESSAGE=1

const fs = require("fs");
const os = require("os");
const path = require("path");

// Nab the authenticated AWS instantiation from aws-auth
const awsauth = require("@c6fc/spellcraft-aws-auth");
const { aws } = awsauth._spellcraft_metadata.functionContext;

// Initialize caches
const artifacts = {};
const awsterraform = { projectName: false, bootstrapBucket: false, bootstrapLocation: false };
const remoteStates = {};

// Set during init() when config.spellcraftProject bootstraps automatically --
// see the init hook below. Anything other than null here means the project
// name came from config, not from a manifest's own bootstrap() call.
let configuredProject = null;

exports._spellcraft_metadata = {
	functionContext: { awsterraform },
	init: async (spellframe) => {
		const project = readConfiguredProject(spellframe);

		if (project) {
			configuredProject = project;
			await bootstrap(project);
		}
	}
}

// Reads config.spellcraftProject from the *consumer's* package.json (the
// same convention @c6fc/spellcraft-terraform uses for config.tf_version), so
// a spell that only ever bootstraps one project can skip calling bootstrap()
// from Jsonnet entirely. This runs during init() -- guaranteed to finish
// before any Jsonnet evaluation starts -- so there's no laziness/ordering
// hazard to navigate the way there is for a manifest-level bootstrap() call.
function readConfiguredProject(spellframe) {
	try {
		const pkg = JSON.parse(fs.readFileSync(path.join(spellframe.baseDir, 'package.json'), 'utf-8'));
		return pkg?.config?.spellcraftProject || null;
	} catch (e) {
		return null;
	}
}

exports.bootstrap = [async function (project) {
	// config.spellcraftProject and an explicit bootstrap() call are mutually
	// exclusive, on purpose: allowing both risked the two silently disagreeing
	// on which project a spell's state actually lives under. Pick one.
	if (configuredProject !== null) {
		throw new Error(
			`[!] bootstrap("${project}") was called from the manifest, but config.spellcraftProject ` +
			`("${configuredProject}") already bootstrapped this spell during init(). Remove this ` +
			`bootstrap() call, or drop config.spellcraftProject from package.json and bootstrap ` +
			`explicitly instead -- a spell can't be bootstrapped under two sources.`
		);
	}

	// A second explicit bootstrap() call with a *different* name would move
	// every later getArtifact()/putArtifact() call to a new namespace
	// mid-manifest, silently. The same name twice is a harmless no-op --
	// getBootstrapBucket()'s own cache makes that cheap -- but a spell has
	// one project; reading another spell's state is what getRemoteState() is
	// for, not a second bootstrap() call.
	if (awsterraform.projectName !== false && awsterraform.projectName !== project) {
		throw new Error(
			`[!] bootstrap("${project}") conflicts with bootstrap("${awsterraform.projectName}"), already ` +
			`called earlier in this process. A spell has one project -- use getRemoteState() to read ` +
			`another spell's state instead of a second bootstrap() call.`
		);
	}

	return await bootstrap(project);
}, "project"];

exports.getArtifact = [async function (name) {
	return await getArtifact(name);
}, "name"];

exports.getBootstrapBucket = [async function () {
	return await getBootstrapBucket();
}];

exports.getRemoteState = [async function (project) {
	return await getRemoteState(project);
}, "project"];

exports.putArtifact = [async function (name, content) {
	return await putArtifact(name, content);
}, "name", "content"];

async function bootstrap(project) {
	const s3 = new aws.S3();
	
	let bucketName;
	let bootstrapBucket = await getBootstrapBucket();

	if (!bootstrapBucket) {
		bucketName = `spellcraft-${Math.random().toString(36).replace(/[^a-z]+/g, '')}-${Math.round(Date.now() / 1000)}`;

		try {
			await s3.createBucket({
				Bucket: bucketName
			}).promise();

			await s3.putBucketTagging({
				Bucket: bucketName,
				Tagging: {
					TagSet: [{
						Key: "spellcraft-backend",
						Value: "true"
					}]
				}
			}).promise();

			await s3.putBucketVersioning({
				Bucket: bucketName,
				VersioningConfiguration: {
					MFADelete: "Disabled",
					Status: "Enabled"
				}
			}).promise();

			await s3.putPublicAccessBlock({
				Bucket: bucketName,
				PublicAccessBlockConfiguration: {
					BlockPublicAcls: true,
					BlockPublicPolicy: true,
					IgnorePublicAcls: true,
					RestrictPublicBuckets: true
				}
			}).promise();

			await s3.putBucketPolicy({
				Bucket: bucketName,
				Policy: JSON.stringify({
					Version: "2012-10-17",
					Statement: [{
						Sid: "AllowSSLOnly",
						Principal: "*",
						Action: "s3:*",
						Effect: "Deny",
						Resource: [
							`arn:aws:s3:::${bucketName}`,
							`arn:aws:s3:::${bucketName}/*`
						],
						Condition: {
							Bool: {
								"aws:SecureTransport": false
							}
						}
					}]
				})
			}).promise();
		} catch (e) {
			console.log(`SpellCraft error: Unable to create bucket: ${e}`);
			process.exit(1);
		}

		console.log(`[+] Created bootstrap bucket ${bucketName}`);

		// Store the bare name, not an ARN. Every consumer (getArtifact,
		// putArtifact, getRemoteState) passes this straight to S3 as `Bucket:`,
		// which only accepts a name -- and the discovery path below already
		// returns a name, so an ARN here made the two paths disagree.
		bootstrapBucket = bucketName;
	} else {
		bucketName = bootstrapBucket;
		console.log(`[+] Using bootstrap bucket ${bucketName}`);
	}

	let bootstrapLocation = await s3.getBucketLocation({
		Bucket: bucketName
	}).promise();

	bootstrapLocation = (bootstrapLocation.LocationConstraint == '') ? "us-east-1" : bootstrapLocation.LocationConstraint;

	awsterraform.projectName = project;
	awsterraform.bootstrapBucket = bootstrapBucket;
	awsterraform.bootstrapLocation = bootstrapLocation;

	return {
		terraform: {
			backend: {
				s3: {
					bucket: bucketName,
					key: `spellcraft/${project}/terraform.tfstate`,
					region: bootstrapLocation
				}
			}
		}
	}
}

async function getBootstrapBucket() {

	if (!!awsterraform.bootstrapBucket) {
		return awsterraform.bootstrapBucket;
	}

	const s3 = new aws.S3();
	const buckets = await s3.listBuckets().promise();

	const arns = buckets.Buckets
		.map(e => e.Name)
		.filter(e => /^spellcraft-[a-z]*?-\d{10}$/.test(e));

	if (arns.length == 1) {
		// Cache the discovery. Callers await this function for its side effect
		// and then read awsterraform.bootstrapBucket; without this write that
		// property stays unset unless bootstrap() ran in the same process.
		awsterraform.bootstrapBucket = arns[0];

		return arns[0];
	}

	if (arns.length > 1) {
		throw new Error("[!] More than one bootstrap bucket exists in this account. Fix this before continuing.");
	}

	return false;
}

async function getRemoteState(project) {

	if (!!!remoteStates[project]) {
		await getBootstrapBucket();

		const s3 = new aws.S3({ region: awsterraform.bootstrapLocation });

		let stateJson;

		try {
			stateJson = await s3.getObject({
				Bucket: awsterraform.bootstrapBucket,
				Key: `spellcraft/${project}/terraform.tfstate`
			}).promise();

		} catch(e) {
			throw new Error(`[!] Unable to retrieve remote state for project [ ${project} ]: ${e}`);
		}

		const state = JSON.parse(stateJson.Body);

		const resources = state.resources.reduce((a, c) => {
			let path;

			if (c.mode == "data") {
				a.data = (!a.data) ? {} : a.data;
				a.data[c.type] = (!a.data[c.type]) ? {} : a.data[c.type];

				path = a.data[c.type];
			} else {
				a[c.type] = (!a[c.type]) ? {} : a[c.type];

				path = a[c.type];
			}

			path[c.name] = (c.instances.length == 1) ? c.instances[0].attributes : c.instances.map(e => e.attributes);

			return a;
		}, {});

		resources.outputs = Object.keys(state.outputs).reduce((a, c) => {
			a[c] = state.outputs[c].value;

			return a;
		}, {});

		// console.log(resources.outputs);

		remoteStates[project] = resources;
	}

	// Read back through the cache. `resources` is block-scoped to the branch
	// above, so returning it directly threw a ReferenceError on every call.
	return remoteStates[project];
}

// Both artifact functions key their S3 object off `awsterraform.projectName`,
// which only `bootstrap()` sets. Jsonnet's laziness means a manifest that
// calls `bootstrap()` without threading its result into whatever calls
// getArtifact/putArtifact can still evaluate this first -- and without this
// guard, `projectName` was silently `false`, so the object landed at
// `spellcraft/false/artifacts/<name>` instead of failing.
function assertBootstrapped(fnName) {
	if (!awsterraform.projectName) {
		throw new Error(
			`[!] ${fnName}() was called before bootstrap() set a project name. ` +
			`Call aws.bootstrap(project) first, and thread its return value into ` +
			`whatever calls ${fnName}() so evaluation order is forced -- Jsonnet ` +
			`does not otherwise guarantee bootstrap() runs first.`
		);
	}
}

async function getArtifact(name) {
	assertBootstrapped('getArtifact');

	if (!!!artifacts[name]) {
		await getBootstrapBucket();

		const s3 = new aws.S3({ region: (awsterraform.bootstrapLocation || 'us-east-1') });

		const object = await s3.getObject({
			Bucket: awsterraform.bootstrapBucket,
			Key: `spellcraft/${awsterraform.projectName}/artifacts/${name}`
		}).promise();

		// putArtifact stores JSON, so decode it back into the value that was
		// stored. Returning the raw Body handed Jsonnet a Buffer, which
		// serialises as {"type":"Buffer","data":[...]} rather than the artifact
		// -- and disagreed with the warm-cache path, which returns the original
		// object. Fall back to the plain string for artifacts written by hand.
		const body = object?.Body?.toString();

		try {
			artifacts[name] = JSON.parse(body);
		} catch (e) {
			artifacts[name] = body;
		}
	}

	return artifacts[name];
}

async function putArtifact(name, content) {
	assertBootstrapped('putArtifact');

	// Skip the write only when this exact content is already cached. The old
	// guard was `!artifacts[name] !== content`, comparing a boolean to the
	// content, which was always true.
	if (artifacts[name] !== content) {
		await getBootstrapBucket();

		const s3 = new aws.S3({ region: (awsterraform.bootstrapLocation || 'us-east-1') });

		const object = await s3.putObject({
			Body: Buffer.from(JSON.stringify(content)),
			Bucket: awsterraform.bootstrapBucket,
			Key: `spellcraft/${awsterraform.projectName}/artifacts/${name}`
		}).promise();

		artifacts[name] = content;
	}

	return true;
}