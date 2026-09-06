// The Jsonnet face of this plugin. Native functions from module.js are reached
// through std.native(), namespaced by package name; everything else here is
// ordinary Jsonnet built on top of them.
//
// Doc comments below are lifted into README.md by `npx spellcraft doc`.

local auth = import "@c6fc/spellcraft-aws-auth/module.libsonnet";

{
	// Passthrough of @c6fc/spellcraft-aws-auth, so a spell that imports this
	// module can reach `aws.auth.getCallerIdentity()` without a second import.
	auth: auth,

	/**
	 * Prepares the S3 backend for a project, creating the bootstrap bucket if it
	 * does not exist yet, and returns the Terraform `backend` block for it.
	 *
	 * This is the one function here that writes: it creates the bucket on first
	 * use. State and artifacts for every project live in that one bucket, keyed
	 * by project name.
	 *
	 * `getArtifact()` and `putArtifact()` key their object off the project name
	 * this sets, so either one throws if it runs before this has. Jsonnet does
	 * not guarantee that order on its own -- thread this function's result into
	 * whatever calls them, the way `enableServices()` is threaded elsewhere in
	 * this ecosystem, rather than merely calling both in the same manifest.
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
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * { "backend.tf.json": aws.bootstrap("my-project") }
	 *
	 * // Returns:
	 * // {
	 * //   "terraform": {
	 * //     "backend": {
	 * //       "s3": {
	 * //         "bucket": "spellcraft-random-0123456789",
	 * //         "key": "spellcraft/my-project/terraform.tfstate",
	 * //         "region": "us-east-1"
	 * //       }
	 * //     }
	 * //   }
	 * // }
	 */
	bootstrap(project):: std.native("@c6fc/spellcraft-aws-terraform:bootstrap")(project),

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
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * local backend = aws.bootstrap("my-project");
	 * local shared = if backend != null then aws.getArtifact("network") else null;
	 *
	 * { "app.tf.json": { resource: { aws_instance: { app: { subnet_id: shared.subnetId } } } } }
	 */
	getArtifact(name):: std.native("@c6fc/spellcraft-aws-terraform:getArtifact")(name),

	/**
	 * The name of the bootstrap bucket, or `false` when none exists yet.
	 *
	 * Discovery is by naming convention rather than by tag, and more than one
	 * match in the account is an error — there is meant to be exactly one.
	 *
	 * @returns {string|boolean} the bucket name, or false
	 * @example
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * { "state.json": { bucket: aws.getBootstrapBucket() } }
	 */
	getBootstrapBucket():: std.native("@c6fc/spellcraft-aws-terraform:getBootstrapBucket")(),

	/**
	 * Reads the Terraform state of another SpellCraft project in the same account.
	 *
	 * Use it to consume another spell's outputs at evaluation time. The project
	 * name is the one passed to that spell's `bootstrap()`.
	 *
	 * @param {string} project - the other spell's project name
	 * @returns {object} that project's Terraform state
	 * @example
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * local network = aws.getRemoteState("network");
	 *
	 * { "app.tf.json": { output: { vpc: { value: network.outputs.vpc_id.value } } } }
	 */
	getRemoteState(project):: std.native("@c6fc/spellcraft-aws-terraform:getRemoteState")(project),

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
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * local backend = aws.bootstrap("my-project");
	 *
	 * {
	 *     "backend.tf.json": backend,
	 *     "meta.json": { stored: if backend != null then aws.putArtifact("network", { subnetId: "subnet-abc123" }) else null },
	 * }
	 */
	putArtifact(name, content):: std.native("@c6fc/spellcraft-aws-terraform:putArtifact")(name, content),

	/**
	 * Builds the full set of AWS provider declarations for a spell.
	 *
	 * Returns one aliased provider per region your credentials can see — the
	 * alias is the region name, so resources bind to it as `aws.us-west-2` — plus
	 * an unaliased default provider for the region you name. This is what lets
	 * plugins like `@c6fc/spellcraft-aws-s3` take a region as an argument and
	 * place resources in it without every spell wiring providers by hand.
	 *
	 * The region list comes from a live `describeRegions` call, so the set
	 * reflects what the account actually has enabled.
	 *
	 * @param {string} default - region for the unaliased default provider
	 * @returns {object[]} provider declarations, for the `provider` key of a `.tf.json`
	 * @example
	 * local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
	 *
	 * { "providers.tf.json": { provider: aws.providerAliases("us-east-2") } }
	 *
	 * // Returns:
	 * // [
	 * //   { "aws": { "alias": "us-east-1", "region": "us-east-1" } },
	 * //   { "aws": { "alias": "us-west-2", "region": "us-west-2" } },
	 * //   ...
	 * //   { "aws": { "region": "us-east-2" } }
	 * // ]
	 */
	providerAliases(default):: [{
		aws: {
			alias: region,
			region: region
		}
	} for region in std.map(
		function(x) x.RegionName,
		std.native("@c6fc/spellcraft-aws-auth:aws")('{ "service": "EC2", "params": { "region": "us-east-1" } }', "describeRegions", "{}").Regions
	)] + [{
		aws: {
			region: default
		}
	}]
}
