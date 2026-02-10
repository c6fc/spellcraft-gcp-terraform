// Don't try to 'import' your spellcraft native functions here.
// Use std.native(function)(..args) instead

local auth = import "@c6fc/spellcraft-gcp-auth/module.libsonnet";

local normalize(name) = std.native("@c6fc/spellcraft-gcp-terraform:normalizeResourceName")(name);
local shortHash(name) = std.native("@c6fc/spellcraft-gcp-terraform:shortHash")(std.manifestJsonEx(name, ''));

local join_objects(objs) = 
	local aux(arr, i, running) =
		if i >= std.length(arr) then
			running
		else
			aux(arr, i + 1, std.mergePatch(running, arr[i])) tailstrict;
	aux(objs, 0, {});

local org_map(name, anchor, fullbody) =
	local recurse(parent, resource, rawbody) = 
		// Pre-define and hide interpreted to avoid lots of conditionals.
		local body = {
			type:: "",
			iam_members:: [],
			services:: [],
			service_accounts:: [],
			audit_config:: [],
			constraints:: [],
			custom_constraints:: [],
			custom_roles:: [],
			children:: [],
		} + rawbody;

		local thisResource = normalize("%s_%s" % [resource, body.name]);

		local gParent = if (body.type == "project") then
				"projects/${google_project.%s.project_id}" % thisResource
			else
				"${google_folder.%s.name}" % thisResource;

		std.mergePatch(std.prune({
			resource: {
				[if body.type == "project" then 'google_project' else null]: {
					[thisResource]: {
						name: body.name,
						project_id: body.name,
						deletion_protection: false,

						[if std.startsWith(parent, "organizations/") then 'org_id' else null]: std.split(parent, "/")[1],
						[if std.startsWith(parent, "folders/") then 'folder_id' else null]: std.split(parent, "/")[1],
					}
				},

				[if body.type == "folder" then 'google_folder' else null]: {
					[thisResource]: body + {
						project_id: body.name,
						parent: parent,
						deletion_protection: false,
					}
				},

				[if (body.type == "project") then 'google_project_iam_member' else 'google_folder_iam_member']: {
					["%s-iam-%s-%s" % [thisResource, normalize(item.role), shortHash(item)]]: item + {
						[if body.type == "project" then 'project' else null]: "${google_project.%s.project_id}" % thisResource,
						[if body.type == "folder" then 'folder' else null]: "${google_folder.%s.name}" % thisResource,
					} for item in body.iam_members
				},

				google_project_services: {
					["%s-services-%s" % [thisResource, service]]: {
						project: "${google_project.%s.project_id}" % thisResource,
						service: service,
						disable_on_destroy: false,
						disable_dependent_services: false
					} for service in body.services
				},

				google_org_policy_policy: {
					["%s-constraint-%s" % [thisResource, normalize(item.name)]]: {						
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
				} + {
					["%s-constraint-%s" % [thisResource, normalize(item.name)]]: {						
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

					} for item in std.filter(
						function (x) (std.objectHas(x, "rules") || std.objectHas(x, "spec") || std.objectHas(x, "dry_run_spec")),
						body.custom_constraints
					)
				},

				google_org_policy_custom_constraint: {
					["%s-customconstraint-%s" % [thisResource, normalize(item.name)]]: item + {
						parent: gParent,
					} for item in body.custom_constraints
				}


			}
		}), if (body.type == "folder" && std.length(body.children) > 0) then 
			join_objects([
				recurse("folders/${google_folder.%s.name}" % thisResource, thisResource, item)
				for item in body.children
			])
		else { });

	join_objects([
		recurse(anchor, name, item)
		for item in fullbody.children
	]);

local projectAnchor(name, map) = 
	local resources = org_map(name, if (std.objectHas(map, "parent")) then map.parent else "organizations/12345", map) tailstrict;
	std.mergePatch({
		resource: {
			tlo: true
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

	googleOrgProject(name, map):: projectAnchor(name, map),

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