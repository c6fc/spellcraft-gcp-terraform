/*
	This file should manifest all the exposed features of your module
	so users can see examples of how they are used, and the output they
	generate.
*/

local gcp = import "module.libsonnet";
local domain = gcp.auth.getProjectMetadata().organizationDomain;
local directoryId = gcp.auth.getProjectMetadata().directoryId;

// putArtifact() keys its object off the project name bootstrap() sets, and
// Jsonnet doesn't guarantee bootstrap() runs first just because it's written
// first -- binding it to a local and depending on that value (below) is what
// actually forces the order.
local bootstrap = gcp.bootstrap("spellcraft-gcp-terraform-module-test");

{
	"bootstrap.tf.json": bootstrap,
	"test.tf.json": {
		output: {
			putArtifact: {
				value: if bootstrap != null then gcp.putArtifact("putArtifactTest", "mytest2") else null
			},
			getBootstrapBucket: {
				value: gcp.getBootstrapBucket()
			},

			/* These can only be used after the project is created and the contents populated.
			getArtifact: {
				value: gcp.getArtifact("putArtifactTest")
			},
			getRemoteState: {
				value: std.parseJson(gcp.getRemoteState("spellcraft-gcp-terraform-module-test"))
			}
			*/
		}
	},
	"projectStructure.tf.json": gcp.googleOrgProject("test", "us-west2", {
		type: "folder",
		name: "folder1",
		children: [{
			type: "folder",
			name: "folder2",

			iam_members: [{
				role: "roles/resourcemanager.folderAdmin",
				members: ["domain:%s" % domain],
			}],

			constraints: [{
				name: "iam.allowedPolicyMemberDomains",
				rules: [{
					values: { allowed_values: [directoryId] },
				}]
			}],

			children: [{
				type: "project",
				name: "project1",
				provider_regions: ["us-central1"],

				audit_config: {
					"allServices": {
						log_types: [
							"ADMIN_READ",
							{ log_type: "DATA_WRITE", exempted_members: ["domain:%s" % domain] }
						]
					}
				},

				custom_roles: {
					// Custom role names cannot contain underscores
					exampleCustomRole: {
						description: "A test custom role",
						permissions: ["storage.objects.get", "storage.objects.list"],
					}
				},

				service_accounts: {
					"test-sa": {
						display_name: "A test SA",
						identity_policies: [
							"roles/storage.viewer",
							"custom/exampleCustomRole",
							{
								role: "roles/storage.admin",
								condition: [{
									title: "expires_in_2030",
									expression: "request.time < timestamp('2030-01-01T00:00:00-06:00')"
								}]
							}
						],
						impersonation_policies: [{
							role: "roles/iam.serviceAccountTokenCreator",
							member: "domain:%s" % domain,
							condition: [{
								title: "also_expires_in_2030",
								expression: "request.time < timestamp('2030-01-01T00:00:00-06:00')"
							}]
						}],
						impersonation_roles: {
							["domain:%s" % domain]: ["roles/iam.serviceAccountUser"],
						}
					}
				}
			}]
		}]
	}),
	'providers.tf.json':: {
		provider: gcp.providerAliases("us-west2", {}, "us-west")
	}
}