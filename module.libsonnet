// The Jsonnet face of this plugin. Native functions from module.js are reached
// through std.native(), namespaced by package name; everything else here is
// ordinary Jsonnet built on top of them.
//
// Doc comments below are lifted into README.md by `npx spellcraft doc`.

local auth = import "@c6fc/spellcraft-gcp-auth/module.libsonnet";

local projectMetadata = auth.getProjectMetadata();

local normalize(name) = std.native("@c6fc/spellcraft-gcp-terraform:normalizeResourceName")(name);
local shortHash(name) = std.native("@c6fc/spellcraft-gcp-terraform:shortHash")(std.manifestJsonEx(name, ''));
local enableServices(services) = std.native("@c6fc/spellcraft-gcp-terraform:enableServices")(std.manifestJsonEx(services, ""));

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
			custom_roles:: {},
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
					project: "${terraform_data.%s-service-depends.output}" % thisResource,
					alias: "%s" % [body.name],
					region: region
				}
			}, {
				google: {
					project: "${terraform_data.%s-service-depends.output}" % thisResource,
					alias: "%s-%s" % [body.name, region],
					region: region
				}
			}] + [{
				google: {
					project: "${terraform_data.%s-service-depends.output}" % thisResource,
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
						project_id: "%s-%s-${random_bytes.%s-org-random-suffix.hex}" % [normalize(body.name), shortHash(body + parent), name],

						[if std.startsWith(parent, "organizations/") then 'org_id' else null]: std.split(parent, "/")[1],
						[if std.startsWith(parent, "folders/") then 'folder_id' else null]: std.split(parent, "/")[1],
					}
				},

				[if body.type == "folder" then 'google_folder' else null]: {
					[thisResource]: {
						name:: "",
					} + body + {
						display_name: "%s" % [body.name],
						parent: parent,
						deletion_protection: false
					}
				},

				[if body.type == "project" then 'google_project_service' else null]: {
					["%s-services-%s" % [thisResource, std.split(service, ".")[0]]]: {
						project: "${google_project.%s.project_id}" % thisResource,
						service: service,
						disable_on_destroy: false,
						disable_dependent_services: false,
					} for service in body.services
				},

				[if body.type == "project" then 'terraform_data' else null]: {
					["%s-service-depends" % [thisResource]]: {
						input: "${google_project.%s.project_id}" % thisResource,
						depends_on: ["google_project_service.%s-services-%s" % [thisResource, std.split(service, ".")[0]] for service in body.services]
					},
					["%s-oob-service-depends" % [thisResource]]: {
						input: if (std.length(body.services) > 0) then enableServices(body.services) else true
					}
				},

				[if body.type == "project" then 'google_project_iam_member' else 'google_folder_iam_member']: {
					["%s-member-%s" % [thisResource, shortHash(item + member)]]: {
						
						[if body.type == "project" then 'project' else null]: "${google_project.%s.project_id}" % thisResource,
						[if body.type == "folder" then 'folder' else null]: "${google_folder.%s.name}" % thisResource,
						
						role: item.role,
						member: member,
						[if body.type == "project" then 'depends_on']: ["terraform_data.%s-service-depends" % thisResource],
					} for item in body.iam_members for member in item.members
				} + {
					["%s-sa-permissions-%s-%s" % [thisResource, normalize(sa), shortHash(sa+entry)]]: (if std.type(entry) == "string" then {
						role: entry
					} else entry) + {
						role: (if std.startsWith(super.role, "custom/") then "projects/${google_project.%s.project_id}/roles/%s" % [thisResource, std.split(super.role, "/")[1]] else super.role),
						project: "${google_project.%s.project_id}" % thisResource,
						member: "serviceAccount:${google_service_account.%s-sa-%s.email}" % [thisResource, normalize(sa)],
						depends_on: ["terraform_data.%s-service-depends" % thisResource],
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
						),
						[if body.type == "project" then 'depends_on']: ["terraform_data.%s-service-depends" % thisResource],
					} for k in std.objectFields(body.audit_config)
				},

				[if body.type == "project" then 'google_project_iam_custom_role' else null]: {
					["%s-customrole-%s" % [thisResource, role]]: body.custom_roles[role] + {
						
						// Fail if the name contains underscores. I agree this is a dumb limitation
						local failWithUnderscores = std.assertEqual(std.count("_", role), 0),
						
						project: "${google_project.%s.project_id}" % thisResource,
						role_id: role,
						title: role,
						depends_on: ["terraform_data.%s-service-depends" % thisResource],
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
						[if body.type == "project" then 'depends_on']: ["terraform_data.%s-service-depends" % thisResource],
					} for item in body.constraints
				},

				// service accounts:
				[if body.type == "project" then 'google_service_account' else null]: {
					["%s-sa-%s" % [thisResource, normalize(sa)]]: {
						project: "${google_project.%s.project_id}" % thisResource,
						account_id: sa,
						display_name: body.service_accounts[sa].display_name,
						depends_on: ["terraform_data.%s-service-depends" % thisResource],
					} for sa in std.objectFields(body.service_accounts)
				},

				[if body.type == "project" then 'google_service_account_iam_member' else null]: {
					// impersonation_roles
					["%s-sa-%s-member-%s" % [thisResource, normalize(sa), shortHash(sa+member+role)]]: {
						service_account_id: "${google_service_account.%s-sa-%s.name}" % [thisResource, normalize(sa)],
						role: role,
						member: member,
						depends_on: ["terraform_data.%s-service-depends" % thisResource],
					}
					for sa in std.objectFields(body.service_accounts)
					for member in (if std.objectHas(body.service_accounts[sa], 'impersonation_roles') then std.objectFields(body.service_accounts[sa].impersonation_roles) else [])
					for role in body.service_accounts[sa].impersonation_roles[member]
				} + {
					// impersonation_policies
					["%s-sa-%s-member-%s" % [thisResource, normalize(sa), shortHash(sa+policy)]]: policy + {
						service_account_id: "${google_service_account.%s-sa-%s.name}" % [thisResource, normalize(sa)],
						depends_on: ["terraform_data.%s-service-depends" % thisResource],
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
	local all_resources = std.mergePatch({
		resource: {
			random_bytes: {
				["%s-org-random-suffix" % name]: {
					length: 2
				}
			}
		},
		output: {
			"org-api-activation": {
				value: enableServices(["orgpolicy.googleapis.com"])
			}
		}
	}, resources);
	local complete_resource_name = "%s-org-complete" % name;
	local all_deps = [
		"%s.%s" % [res_type, res_name]
		for res_type in std.objectFields(all_resources.resource)
		for res_name in std.objectFields(all_resources.resource[res_type])
		if !(res_type == "terraform_data" && res_name == complete_resource_name)
	];
	std.mergePatch(all_resources, {
		resource: {
			terraform_data: {
				[complete_resource_name]: {
					input: name,
					depends_on: all_deps
				}
			}
		}
	});


{
	// JS Native functions are already documented in spellcraft_modules/foo.js
	// but need to be specified here to expose them through the import

	// Passthrough of @c6fc/spellcraft-gcp-auth, so a spell that imports this
	// module can reach `gcp.auth.getProjectMetadata()` without a second import.
	auth: auth,

	/**
	 * Prepares the GCS backend for a spell, creating the bootstrap bucket if it
	 * does not exist yet, and returns the Terraform `backend` block for it.
	 *
	 * This is the one function here that writes: it creates the bucket on first
	 * use. State and artifacts for every spell live in that bucket, keyed by the
	 * name you pass.
	 *
	 * `getArtifact()` and `putArtifact()` key their object off the project name
	 * this sets, so either one throws if it runs before this has. Jsonnet does
	 * not guarantee that order on its own -- thread this function's result into
	 * whatever calls them, rather than merely calling both in the same manifest.
	 *
	 * A spell that only ever bootstraps one project, known ahead of time, can
	 * skip calling this from Jsonnet at all: set `config.spellcraftProject` in
	 * `package.json` and it runs during `init()`, before evaluation starts, so
	 * there's no ordering hazard to think about. The two are mutually
	 * exclusive -- calling this explicitly throws if `config.spellcraftProject`
	 * already bootstrapped the spell, rather than letting the two silently
	 * disagree about which project is live.
	 *
	 * A spell has one project. Calling this again with a *different* name in
	 * the same process throws for the same reason -- to read another spell's
	 * state, use `getRemoteState()`, not a second `bootstrap()` call. The
	 * same name twice is a no-op.
	 *
	 * @param {string} project - names the state prefix; use one per spell
	 * @returns {object} a Terraform block ready to merge into a `.tf.json` file
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * { "backend.tf.json": gcp.bootstrap("my-project") }
	 *
	 * // Returns a terraform.backend.gcs block pointing at the bootstrap bucket,
	 * // prefixed with the project name you passed.
	 */
	bootstrap(project):: std.native("@c6fc/spellcraft-gcp-terraform:bootstrap")(project),

	/**
	 * Reads an artifact previously stored by `putArtifact()`.
	 *
	 * Artifacts are how one spell hands a value to another without a Terraform
	 * data source — the value is fetched while the manifest evaluates, so it can
	 * shape the configuration rather than only appear in it.
	 *
	 * Throws if `bootstrap()` hasn't set a project name yet -- see `bootstrap()`
	 * for why that ordering isn't automatic.
	 *
	 * @param {string} name - the artifact name given to `putArtifact()`
	 * @returns {*} the stored value, parsed back from JSON
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * local backend = gcp.bootstrap("my-project");
	 * local shared = if backend != null then gcp.getArtifact("network") else null;
	 *
	 * { "app.tf.json": { output: { subnet: { value: shared.subnet } } } }
	 */
	getArtifact(name):: std.native("@c6fc/spellcraft-gcp-terraform:getArtifact")(name),

	/**
	 * The name of the bootstrap bucket for the current project.
	 *
	 * @returns {string} the bucket name, `spellcraft-terraform-<project-id>`
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * { "state.json": { bucket: gcp.getBootstrapBucket() } }
	 */
	getBootstrapBucket():: std.native("@c6fc/spellcraft-gcp-terraform:getBootstrapBucket")(),

	/**
	 * Reads the Terraform state of another SpellCraft spell in the same GCP
	 * project. Use it to consume another spell's outputs at evaluation time; the
	 * name is the one passed to that spell's `bootstrap()`.
	 *
	 * @param {string} project - the other spell's project name
	 * @returns {object} that spell's Terraform state
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * local network = gcp.getRemoteState("network");
	 *
	 * { "app.tf.json": { output: { subnet: { value: network.outputs.subnet.value } } } }
	 */
	getRemoteState(project):: std.native("@c6fc/spellcraft-gcp-terraform:getRemoteState")(project),

	/**
	 * Builds a whole folder and project tree from one nested description.
	 *
	 * Each node is a `{ type: "folder" | "project", name, children }`, and may
	 * carry `iam_members`, `services` and the other per-node settings the tree
	 * understands. The root's parent defaults to the organization the current
	 * project belongs to; set `parent` on the map to place it elsewhere.
	 *
	 * Alongside the resources it emits the dependency wiring that makes creation
	 * order correct, and registers the services each project needs so they are
	 * enabled before `terraform apply` runs.
	 *
	 * `test.jsonnet` in this package is the fully worked example.
	 *
	 * @param {string} name - prefix for the generated Terraform resource names
	 * @param {string} region - region for the providers the tree exposes
	 * @param {object} map - the root node of the folder/project tree
	 * @returns {object} Terraform `resource` and `output` blocks
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * { "org.tf.json": gcp.googleOrgProject("platform", "us-west2", {
	 *     type: "folder",
	 *     name: "engineering",
	 *     children: [{ type: "project", name: "sandbox" }],
	 *   }) }
	 */
	googleOrgProject(name, region, map):: projectAnchor(name, region, map),

	/**
	 * Stores a value as a JSON artifact in the bootstrap bucket, under this
	 * project's prefix. Read it back with `getArtifact()`.
	 *
	 * Throws if `bootstrap()` hasn't set a project name yet -- see `bootstrap()`
	 * for why that ordering isn't automatic.
	 *
	 * @param {string} name - the artifact name
	 * @param {*} content - any JSON-serialisable value
	 * @returns {boolean} true
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * local backend = gcp.bootstrap("my-project");
	 *
	 * {
	 *     "backend.tf.json": backend,
	 *     "meta.json": { stored: if backend != null then gcp.putArtifact("myArtifact", { someData: someValue }) else null },
	 * }
	 */
	putArtifact(name, content):: std.native("@c6fc/spellcraft-gcp-terraform:putArtifact")(name, content),

	/**
	 * Builds the full set of Google provider declarations for a spell.
	 *
	 * Returns one aliased provider per Compute region — the alias is the region
	 * name, so resources bind to it as `google.us-west2` — plus an unaliased
	 * default for the region you name. `options` is merged into every provider,
	 * which is where a shared `project` or `billing_project` belongs. Pass a
	 * `filter` to keep only regions whose name contains it.
	 *
	 * The region list comes from a live `compute.v1.regions.list` call.
	 *
	 * @param {string} default - region for the unaliased default provider
	 * @param {object} options - merged into every provider declaration
	 * @param {string} [filter=""] - substring the region name must contain
	 * @returns {object[]} provider declarations, for the `provider` key of a `.tf.json`
	 * @example
	 * local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";
	 *
	 * gcp.providerAliases("us-west2", {},  "us-");
	 *
	 * // Returns:
	 * // [
	 * //   { "google": { "alias": "us-east1", "region": "us-east1" } },
	 * //   { "google": { "alias": "us-west2", "region": "us-west2" } },
	 * //   ...
	 * //   { "google": { "region": "us-west2" } }
	 * // ]
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