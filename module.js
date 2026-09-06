'use strict';

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require('crypto');

// Nab the authenticated AWS instantiation from gcp-auth
const gcpauth = require("@c6fc/spellcraft-gcp-auth");
const { google } = gcpauth._spellcraft_metadata.functionContext;
const storage = google.storage('v1');
const compute = google.compute('v1');
const resManager = google.cloudresourcemanager('v3');

const { confirm } = require("@inquirer/prompts");

let cachedProject = null;

// Initialize caches
const artifacts = {};
const gcpterraform = { projectName: null, bootstrapBucket: null };
const remoteStates = {};
const serviceRegistry = new Set();

// Set during init() when config.spellcraftProject bootstraps automatically --
// see the init hook below. Anything other than null here means the project
// name came from config, not from a manifest's own bootstrap() call.
let configuredProject = null;

exports._spellcraft_metadata = {
	functionContext: { gcpterraform },
	init: async (spellframe) => {
		await gcpauth._spellcraft_metadata.init(spellframe);

		spellframe.on('@c6fc/spellcraft-terraform:pre-apply', async () => {
			if (serviceRegistry.size > 0) {
				const servicesArray = Array.from(serviceRegistry);
				console.log(`[spellcraft-gcp-terraform] Enabling registered GCP services on pre-apply: ${servicesArray.join(', ')}`);
				await gcpauth.enableServices[0](JSON.stringify(servicesArray));
				serviceRegistry.clear();
			}
		});

		// Reads config.spellcraftProject from the *consumer's* package.json (the
		// same convention @c6fc/spellcraft-terraform uses for config.tf_version),
		// so a spell that only ever bootstraps one project can skip calling
		// bootstrap() from Jsonnet entirely. This runs here, after auth's own
		// init -- guaranteed to finish before any Jsonnet evaluation starts -- so
		// there's no laziness/ordering hazard to navigate the way there is for a
		// manifest-level bootstrap() call.
		const project = readConfiguredProject(spellframe);

		if (project) {
			configuredProject = project;
			await bootstrap(project);
		}
	},
	requires: ["@c6fc/spellcraft-gcp-auth"]
}

function readConfiguredProject(spellframe) {
	try {
		const pkg = JSON.parse(fs.readFileSync(path.join(spellframe.baseDir, 'package.json'), 'utf-8'));
		return pkg?.config?.spellcraftProject || null;
	} catch (e) {
		return null;
	}
}

exports.enableServices = [function (servicesJson) {
	const services = JSON.parse(servicesJson);
	services.forEach(s => serviceRegistry.add(s));
	return true;
}, "services"];

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
	if (gcpterraform.projectName !== null && gcpterraform.projectName !== project) {
		throw new Error(
			`[!] bootstrap("${project}") conflicts with bootstrap("${gcpterraform.projectName}"), already ` +
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

exports.googleOrgProject = [function (options) {
	return googleOrgProject(JSON.parse(options))
}, "options"];

exports.normalizeResourceName = [function (name) {
	return name.replace(/[^a-zA-Z0-9_-]+/g, "").toLowerCase();
}, "name"];

exports.putArtifact = [async function (name, content) {
	return await putArtifact(name, content);
}, "name", "content"];

exports.shortHash = [function (text) {
	return crypto.createHash('sha1').update(text).digest('hex').substr(-5);
}, "text"];

async function bootstrap(projectName) {
	cachedProject = await gcpauth.getProjectId[0]();

	// Set env vars so Terraform (a child process, spawned later by
	// @c6fc/spellcraft-terraform) picks up the right quota project.
	// USER_PROJECT_OVERRIDE is the same value regardless of which project --
	// ??= is fine there. GOOGLE_CLOUD_QUOTA_PROJECT is not: it used to be
	// ??=, so the *first* bootstrap() in a process won permanently, and a
	// second render for a different project in the same process -- no
	// concurrency required, just reuse -- silently inherited the first
	// project's quota override. Always set it to whichever project this
	// bootstrap() call is actually for.
	process.env.USER_PROJECT_OVERRIDE ??= "true";
	process.env.GOOGLE_CLOUD_QUOTA_PROJECT = cachedProject;

	const targetBucket = `spellcraft-terraform-${cachedProject}`;

	if (!await getBootstrapBucket()) {

		console.log(`No 'spellcraft-terraform' bucket found in project "${cachedProject}".`);

		try {
			const createIt = await confirm({
				message: `Create GCS Bootstrap Bucket in project "${cachedProject}"?`,
				default: true
			});

			if (!createIt) {
				console.log("User cancelled bootstrap bucket creation. Select a different project with `export GOOGLE_CLOUD_PROJECT=<project-id>` and re-run the command.");
				process.exit(0);
			}

			console.log(`[+] Creating GCS Bootstrap Bucket: ${targetBucket}`);
			await storage.buckets.insert({
				project: cachedProject,
				requestBody: {
					name: targetBucket,
					location: 'US', // Defaulting to US multi-region for high availability
					storageClass: 'STANDARD',
					versioning: { enabled: true },
					iamConfiguration: {
						uniformBucketLevelAccess: { enabled: true }
					}
				}
			});
		} catch (e) {
			console.log(e);
			throw new Error(`Failed to discover/create GCS bucket: ${e.message}`);
		}
	}

	gcpterraform.bootstrapBucket = targetBucket;
	gcpterraform.projectName = projectName;

	// Return the Terraform backend configuration object
	return {
		terraform: {
			backend: {
				gcs: {
					bucket: gcpterraform.bootstrapBucket,
					prefix: `spellcraft/${projectName}`
				}
			}
		}
	};
};

async function getBootstrapBucket() {

	if (!!gcpterraform.bootstrapBucket) {
		return gcpterraform.bootstrapBucket;
	}

	if (!cachedProject) {
		cachedProject = await gcpauth.getProjectId[0]();
	}

	try {
		await storage.buckets.get({ bucket: `spellcraft-terraform-${cachedProject}` });
		gcpterraform.bootstrapBucket = `spellcraft-terraform-${cachedProject}`;

		return gcpterraform.bootstrapBucket;
	} catch (e) {
		console.log(`[!] Terraform backend bucket not found in current project: ${cachedProject}`);
		return false
	}
}

async function getRemoteState(project) {

	if (!!!remoteStates[project]) {
		if (!gcpterraform.bootstrapBucket) throw new Error("Module not bootstrapped. Call bootstrap() first.");

		let res;

		try {
			res = await storage.objects.get({
				bucket: gcpterraform.bootstrapBucket,
				object: `spellcraft/${project}/default.tfstate`,
				alt: 'media'
			});
		} catch (e) {
			throw new Error(`Could not find remote state for project: ${project}`);
		}

		const state = JSON.parse(res.data);

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

// Both artifact functions key their object off gcpterraform.projectName,
// which only bootstrap() sets. getBootstrapBucket() alone -- called directly,
// or via getRemoteState() -- sets bootstrapBucket without touching
// projectName, so a guard that only checked bootstrapBucket could pass while
// projectName was still null, and the object landed at
// spellcraft/null/artifacts/<name>.json instead of failing.
function assertBootstrapped(fnName) {
	if (!gcpterraform.projectName) {
		throw new Error(
			`[!] ${fnName}() was called before bootstrap() set a project name. ` +
			`Call bootstrap(project) first, and thread its return value into ` +
			`whatever calls ${fnName}() so evaluation order is forced -- Jsonnet ` +
			`does not otherwise guarantee bootstrap() runs first.`
		);
	}
}

async function getArtifact(name) {
	assertBootstrapped('getArtifact');

	try {
		const res = await storage.objects.get({
			bucket: gcpterraform.bootstrapBucket,
			object: `spellcraft/${gcpterraform.projectName}/artifacts/${name}.json`,
			alt: 'media'
		});
		return res.data;
	} catch (e) {
		return null;
	}
};

async function putArtifact(name, content) {
	assertBootstrapped('putArtifact');

	const res = await storage.objects.insert({
		bucket: gcpterraform.bootstrapBucket,
		name: `spellcraft/${gcpterraform.projectName}/artifacts/${name}.json`,
		media: {
			mimeType: 'application/json',
			body: JSON.stringify(content, null, 2)
		}
	});

	return !!res.data;
};