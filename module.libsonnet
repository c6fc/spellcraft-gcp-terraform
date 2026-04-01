// Don't try to 'import' your spellcraft native functions here.
// Use std.native(function)(..args) instead

local auth = import "@c6fc/spellcraft-gcp-auth/module.libsonnet";

local projectMetadata = auth.getProjectMetadata();

local normalize(name) = std.native("@c6fc/spellcraft-gcp-terraform:normalizeResourceName")(name);
local shortHash(name) = std.native("@c6fc/spellcraft-gcp-terraform:shortHash")(std.manifestJsonEx(name, ''));

local join_objects(objs) = 
	local aux(arr, i, running) =
		if i >= std.length(arr) then
			running
		else
			aux(arr, i + 1, std.mergePatch(running, arr[i])) tailstrict;
	aux(objs, 0, {});

local org_map(name, region, anchor, fullbody) =
	local recurse(parent, resource, rawbody) = 
		// Pre-define and hide interpreted values to avoid lots of conditionals.
		local body = {
			type:: "",
			iam_members:: [],
			services:: [],
			service_accounts:: {},
			audit_config:: {},
			constraints:: [],
			custom_roles:: [],
			children:: [],
			provider_regions:: []
		} + rawbody + {
			services:: std.filter(function(x) x != "", std.uniq(std.sort(super.services + [
				if std.objectHas(rawbody, "iam_members") then "iam.googleapis.com" else "",
				if std.objectHas(rawbody, "service_accounts") then "iam.googleapis.com" else "",
				if std.objectHas(rawbody, "audit_config") then "iam.googleapis.com" else "",
				if std.objectHas(rawbody, "constraints") then "orgpolicy.googleapis.com" else "",
				if std.objectHas(rawbody, "custom_constraints") then "orgpolicy.googleapis.com" else "",
				if std.objectHas(rawbody, "custom_roles") then "iam.googleapis.com" else "",
			])))
		};

		local thisResource = normalize("%s_%s" % [resource, body.name]);

		local gParent = if (body.type == "project") then
				"projects/${google_project.%s.project_id}" % thisResource
			else
				"folders/${google_folder.%s.folder_id}" % thisResource;

		std.mergePatch(std.prune({
			provider: (if body.type == "project" then [{
				google: {
					project: "${google_project.%s.project_id}" % thisResource,
					alias: body.name,
					region: region
				}
			}, {
				google: {
					project: "${google_project.%s.project_id}" % thisResource,
					alias: "%s-%s" % [body.name, region],
					region: region
				}
			}] + [{
				google: {
					project: "${google_project.%s.project_id}" % thisResource,
					alias: "%s-%s" % [body.name, r],
					region: r
				}
			} for r in body.provider_regions] else []),
			resource: {
				[if body.type == "project" then 'google_project' else null]: {
					[thisResource]: {
						deletion_policy: "DELETE",
						billing_account: projectMetadata.billingAccount,
					} + body + {
						project_id: "%s-%s" % [normalize(body.name), shortHash(body + parent)],

						[if std.startsWith(parent, "organizations/") then 'org_id' else null]: std.split(parent, "/")[1],
						[if std.startsWith(parent, "folders/") then 'folder_id' else null]: std.split(parent, "/")[1],
					}
				},

				[if body.type == "folder" then 'google_folder' else null]: {
					[thisResource]: {
						name:: "",
					} + body + {
						display_name: body.name,
						parent: parent,
						deletion_protection: false
					}
				},

				[if body.type == "project" then 'google_project_service' else null]: {
					["%s-services-%s" % [thisResource, std.split(service, ".")[0]]]: {
						project: "${google_project.%s.project_id}" % thisResource,
						service: service,
						disable_on_destroy: false,
						disable_dependent_services: false
					} for service in body.services
				},

				[if body.type == "project" then 'google_project_iam_member' else 'google_folder_iam_member']: {
					["%s-member-%s" % [thisResource, shortHash(item + member)]]: {
						
						[if body.type == "project" then 'project' else null]: "${google_project.%s.project_id}" % thisResource,
						[if body.type == "folder" then 'folder' else null]: "${google_folder.%s.name}" % thisResource,
						
						role: item.role,
						member: member
					} for item in body.iam_members for member in item.members
				} + {
					["%s-sa-permissions-%s-%s" % [thisResource, normalize(sa), shortHash(sa+entry)]]: (if std.type(entry) == "string" then {
						role: entry
					} else entry) + {
						role: (if std.startsWith(super.role, "custom/") then "projects/${google_project.%s.project_id}/roles/%s" % [thisResource, std.split(super.role, "/")[1]] else super.role),
						project: "${google_project.%s.project_id}" % thisResource,
						member: "serviceAccount:${google_service_account.%s-sa-%s.email}" % [thisResource, normalize(sa)],
					}
					for sa in std.objectFields(body.service_accounts)
					for entry in (if std.objectHas(body.service_accounts[sa], 'identity_policies') then body.service_accounts[sa].identity_policies else [])
				},

				[if body.type == "project" then 'google_project_iam_audit_config' else 'google_folder_iam_audit_config']: {
					["%s-audit-%s" % [thisResource, normalize(std.split(k, ".")[0])]]: {
						
						[if body.type == "project" then 'project' else null]: "${google_project.%s.project_id}" % thisResource,
						[if body.type == "folder" then 'folder' else null]: "${google_folder.%s.name}" % thisResource,
						
						service: k,
						audit_log_config: std.map(
							function(e) (if std.type(e) == "string" then {
								log_type: e
							} else e),
							body.audit_config[k].log_types
						)
					} for k in std.objectFields(body.audit_config)
				},

				[if body.type == "project" then 'google_project_iam_custom_role' else null]: {
					["%s-customrole-%s" % [thisResource, role]]: body.custom_roles[role] + {
						
						// Fail if the name contains underscores. I agree this is a dumb limitation
						local failWithUnderscores = std.assertEqual(std.count("_", role), 0),
						
						project: "${google_project.%s.project_id}" % thisResource,
						role_id: role,
						title: role,

					} for role in std.objectFields(body.custom_roles)
				},

				google_org_policy_policy: {
					["%s-constraint-%s" % [thisResource, shortHash(item)]]: {						
						name: "%s/policies/%s" % [gParent, item.name],
						parent: gParent,

						spec: if (std.objectHas(item, 'spec')) then
								item.spec
							else if (std.objectHas(item, 'rules')) then {
								inherit_from_parent: false,
								rules: item.rules
							} else { },

						dry_run_spec: if (std.objectHas(item, 'dry_run_spec')) then
								item.dry_run_spec
							else { },

					} for item in body.constraints
				},

				// service accounts:
				[if body.type == "project" then 'google_service_account' else null]: {
					["%s-sa-%s" % [thisResource, normalize(sa)]]: {
						project: "${google_project.%s.project_id}" % thisResource,
						account_id: sa,
						display_name: body.service_accounts[sa].display_name,
					} for sa in std.objectFields(body.service_accounts)
				},

				[if body.type == "project" then 'google_service_account_iam_member' else null]: {
					// impersonation_roles
					["%s-sa-%s-member-%s" % [thisResource, normalize(sa), shortHash(sa+member+role)]]: {
						service_account_id: "${google_service_account.%s-sa-%s.name}" % [thisResource, normalize(sa)],
						role: role,
						member: member,
					}
					for sa in std.objectFields(body.service_accounts)
					for member in (if std.objectHas(body.service_accounts[sa], 'impersonation_roles') then std.objectFields(body.service_accounts[sa].impersonation_roles) else [])
					for role in body.service_accounts[sa].impersonation_roles[member]
				} + {
					// impersonation_policies
					["%s-sa-%s-member-%s" % [thisResource, normalize(sa), shortHash(sa+policy)]]: policy + {
						service_account_id: "${google_service_account.%s-sa-%s.name}" % [thisResource, normalize(sa)]
					}
					for sa in std.objectFields(body.service_accounts)
					for policy in (if std.objectHas(body.service_accounts[sa], 'impersonation_policies') then body.service_accounts[sa].impersonation_policies else [])
				},
			}
		}), if (body.type == "folder" && std.length(body.children) > 0) then 
			join_objects([
				recurse("folders/${google_folder.%s.folder_id}" % thisResource, thisResource, item)
				for item in body.children
			])
		else { });

	join_objects([
		recurse(anchor, name, item)
		for item in [fullbody]
	]);

local projectAnchor(name, region, map) = 
	local resources = org_map(name, region, if (std.objectHas(map, "parent")) then map.parent else "organizations/%s" % projectMetadata.organizationId, map) tailstrict;
	std.mergePatch({
		output: {
			"org-api-activation": {
				value: auth.enableServices(["orgpolicy.googleapis.com"])
			}
		}
	}, resources);

{
	// JS Native functions are already documented in spellcraft_modules/foo.js
	// but need to be specified here to expose them through the import

	/**
	 * Direct passthrough of the @c6fc/spellcraft-gcp-auth
	 */
	auth: auth,

	/**
	 * Creates a Terraform backend bucket if one doesn't already exist, then
	 * returns a 'backend' object referencing this bucket and a unique path
	 * for this project's state and artifacts.
	 *
	 * @param {string} project
	 * @returns {object} backend
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.bootstrap("myBootstrapTest");
	 *
	 * // Returns:
	 * {
	 *    "terraform": {
	 *        "backend": {
	 *            "gcs": {
	 *                "bucket": "spellcraft-random-0123456789",
	 *                "key": "spellcraft/myBootstrapTest/terraform.tfstate",
	 *            }
	 *        }
	 *    }
	 * }
	 */
	bootstrap(project):: std.native("@c6fc/spellcraft-gcp-terraform:bootstrap")(project),

	/**
	 * Obtains the contents of a named artifact stored alongside this project in the bootstrap
	 * bucket. This artifact is created with 'putArtifact';
	 *
	 * @param {string} name
	 * @returns {object} backend
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.getArtifact("myArtifact");
	 *
	 * // Returns:
	 * <contents of your artifact>
	 */
	getArtifact(name):: std.native("@c6fc/spellcraft-gcp-terraform:getArtifact")(name),

	/**
	 * Attempts to discover the bucket created through bootstrap(), returning the
	 * bucket name if present.
	 *
	 * @returns {string} bucketArn
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.getBootstrapBucket();
	 *
	 * // Returns:
	 * spellcraft-terraform-<project-id>
	 */
	getBootstrapBucket():: std.native("@c6fc/spellcraft-gcp-terraform:getBootstrapBucket")(),

	/**
	 * Read the Terraform state for an adjacent SpellCraft project in the same GCP account
	 *
	 * @param {string} project
	 * @returns {object} state
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.getRemoteState("mySecondProject");
	 *
	 * // Returns:
	 * { full remote state object }
	 */
	getRemoteState(project):: std.native("@c6fc/spellcraft-gcp-terraform:getRemoteState")(project),

	/**
	 * Creates a given folder and project structure, exposing provider aliases
	 * for later use. See test.jsonnet for reference.
	 * 
	 * @param {string} name
	 * @param {string} region
	 * @param {object} map
	 */
	googleOrgProject(name, region, map):: projectAnchor(name, region, map),

	/**
	 * Stores the JSON-encoded balue of 'contents' as a file in the GCS backend bucket using
	 * the project prefix.
	 *
	 * @param {string} name
	 * @param {*} contents
	 * @returns {boolean} true
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.putArtifact("myArtifact", { someData: someValue });
	 *
	 * // Returns:
	 * true
	 */
	putArtifact(name, content):: std.native("@c6fc/spellcraft-gcp-terraform:putArtifact")(name, content),

	/**
	 * Stores the JSON-encoded value of 'contents' as a file in the GCS backend bucket using
	 * the project prefix. If 'filter' is provided, only region names that string match
	 * will be included.
	 *
	 * @param {string} default
	 * @param {string} options
	 * @param {string} filter
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform";
	 *
	 * gcp.providerAliases("us-west2");
	 *
	 * // Returns:
	 * [{ google: {
	 *		region: "us-west2"
	 * }}, { google: {
	 *		region: "us-east1",
			alias: "us-east1"
	 * }}, ...]
	 */
	providerAliases(default, options, filter=""):: [{
		google: options + {
			alias: region,
			region: region
		}
	} for region in std.filterMap(
		function(x) filter != false && (std.length(filter) < 1 || std.length(std.findSubstr(filter, x.name)) > 0),
		function(x) x.name,
		std.native("@c6fc/spellcraft-gcp-auth:api")('compute.v1.regions.list', '{"project":"%s"}' % std.native("@c6fc/spellcraft-gcp-auth:getProjectId")()).items
	)] + [{
		google: options + {
			region: default
		}
	}]
}