'use strict';

const fs = require("fs");
const os = require("os");
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
	},
	requires: ["@c6fc/spellcraft-gcp-auth"]
}

exports.enableServices = [function (servicesJson) {
	const services = JSON.parse(servicesJson);
	services.forEach(s => serviceRegistry.add(s));
	return true;
}, "services"];

exports.bootstrap = [async function (project) {
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

	// set env vars to ensure terraform uses the correct project
	process.env.USER_PROJECT_OVERRIDE ??= "true";
	process.env.GOOGLE_CLOUD_QUOTA_PROJECT ??= cachedProject;

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

	return resources;
}

async function getArtifact(name) {
	if (!gcpterraform.bootstrapBucket) throw new Error("Module not bootstrapped. Call bootstrap() first.");

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
	if (!gcpterraform.bootstrapBucket) throw new Error("Module not bootstrapped. Call bootstrap() first.");

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