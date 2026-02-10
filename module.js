'use strict';

process.env.AWS_SDK_JS_SUPPRESS_MAINTENANCE_MODE_MESSAGE=1

const fs = require("fs");
const os = require("os");
const crypto = require('crypto');

// Nab the authenticated AWS instantiation from gcp-auth
const gcpauth = require("@c6fc/spellcraft-gcp-auth");
const { google } = gcpauth._spellcraft_metadata.functionContext;
const storage = google.storage('v1');
const compute = google.compute('v1');

let cachedProject = null;

// Initialize caches
const artifacts = {};
const gcpterraform = { projectName: null, bootstrapBucket: null };
const remoteStates = {};

exports._spellcraft_metadata = {
	functionContext: { gcpterraform },
	init: gcpauth._spellcraft_metadata.init
}

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
	return name.replace(/[^a-zA-Z0-9_-]+/g, "");
}, "name"];

exports.putArtifact = [async function (name, content) {
	return await putArtifact(name, content);
}, "name", "content"];

exports.shortHash = [function (text) {
	return crypto.createHash('sha1').update(text).digest('hex').substr(-5);
}, "text"];

async function bootstrap(projectName) {
	cachedProject = await gcpauth.getProjectId[0]();
	const targetBucket = `spellcraft-terraform-${cachedProject}`;
    
    if (!await getBootstrapBucket()) {
         try {
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
        } catch(e) {
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
        // 1. Try to find existing bucket
        await storage.buckets.get({ bucket: `spellcraft-terraform-${cachedProject}` });
        gcpterraform.bootstrapBucket = `spellcraft-terraform-${cachedProject}`;

        return gcpterraform.bootstrapBucket;
    } catch (e) {
    	return false;
    };

	return false;
}

async function getRemoteState(project) {

	if (!!!remoteStates[project]) {
		if (!gcpterraform.bootstrapBucket) throw new Error("Module not bootstrapped. Call bootstrap() first.");

		try {
	        const res = await storage.objects.get({
	            bucket: gcpterraform.bootstrapBucket,
	            object: `spellcraft/${project}/default.tfstate`,
	            alt: 'media'
	        });
	        return res.data;
	    } catch (e) {
	        throw new Error(`Could not find remote state for project: ${project}`);
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