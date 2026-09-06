# @c6fc/spellcraft-aws-terraform

S3 state backend, remote state, artifacts and provider aliases for
[SpellCraft](https://github.com/c6fc/spellcraft).

[![NPM version](https://img.shields.io/npm/v/@c6fc/spellcraft-aws-terraform.svg?style=flat)](https://www.npmjs.com/package/@c6fc/spellcraft-aws-terraform)
[![License](https://img.shields.io/npm/l/@c6fc/spellcraft-aws-terraform.svg?style=flat)](https://opensource.org/licenses/MIT)

This is the AWS half of the Terraform story: it decides where state lives, hands
one spell the values another produced, and declares the providers that
region-aware plugins bind to. `@c6fc/spellcraft-terraform` runs the apply;
this tells it what to apply against.

```bash
npm install --save @c6fc/spellcraft-aws-terraform @c6fc/spellcraft-terraform
```

## A complete spell

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";
local s3 = import "@c6fc/spellcraft-aws-s3/module.libsonnet";

{
	// State backend, and the bucket to hold it. Created on first use.
	"backend.tf.json": aws.bootstrap("my-project"),

	// One aliased provider per region, plus an unaliased default.
	"providers.tf.json": { provider: aws.providerAliases("us-east-1") },

	"buckets.tf.json": s3.bucket("artifacts", "us-west-2"),
}
```

```bash
npx spellcraft terraform-apply manifest.jsonnet
```

Three things happen before Terraform sees anything: credentials resolve, the
backend bucket is created if it is missing, and the region list is fetched to
build the providers. The rendered `.tf.json` already contains the answers.

## The bootstrap bucket

`bootstrap(project)` returns the Terraform `backend` block and makes sure the
bucket behind it exists. There is **one bucket per account**, discovered by
naming convention — `spellcraft-<random>-<digits>` — and shared by every spell,
which is why `project` is a required argument: it becomes the key prefix that
separates one spell's state from another's.

Finding more than one candidate bucket is an error rather than a guess.

`getArtifact()` and `putArtifact()` (below) both key their object off the
project name `bootstrap()` records, so either one throws if it runs before
some `bootstrap()` call has set it. Jsonnet doesn't otherwise guarantee that
order — see the warning under "Sharing values between spells" for how to make
it explicit.

### Skipping bootstrap() entirely

Not every spell needs its project name computed at render time. If it's
known ahead of time, set it in `package.json` instead:

```json
{
	"config": {
		"spellcraftProject": "my-project"
	}
}
```

This bootstraps during `init()` — before any Jsonnet evaluation starts — so
there's no ordering hazard to navigate at all: no threading a return value
through, no risk of `getArtifact()`/`putArtifact()` running first. It also
sidesteps a subtler hazard entirely: `bootstrap()`'s state lives in a
module-level object shared by every `SpellFrame` in the process, so two
renders for two different projects running concurrently (embedding
`SpellFrame` as a library, rather than one process per `spellcraft` CLI
invocation) could otherwise cross-contaminate. A config-driven project name
is the same for every render in that process, so there's nothing left to
race on.

`config.spellcraftProject` and an explicit `bootstrap()` call are mutually
exclusive — set the former and the latter throws, rather than risking the
two silently disagreeing about which project is live.

## Sharing values between spells

Two ways, both resolved while the manifest evaluates rather than at apply time.

**Remote state** reads another spell's outputs:

```jsonnet
local network = aws.getRemoteState("network");

{
	"app.tf.json": {
		resource: {
			aws_instance: {
				app: { subnet_id: network.outputs.subnet_id.value },
			},
		},
	},
}
```

**Artifacts** are arbitrary JSON values written under a project's prefix,
for things that aren't Terraform outputs at all. Unlike `getRemoteState()`,
they use *this* spell's own project — the one passed to `bootstrap()` — so
`bootstrap()` has to run first:

```jsonnet
local backend = aws.bootstrap("my-project");

{
	"backend.tf.json": backend,
	"meta.json": { ok: if backend != null then aws.putArtifact("build", { image: "app:1.4.2" }) else null },
}
```

```jsonnet
local build = aws.getArtifact("build");
```

Jsonnet evaluates lazily and in no guaranteed field order, so merely calling
`bootstrap()` somewhere in the manifest doesn't make it run before
`putArtifact()`/`getArtifact()` elsewhere in the same manifest — the call that
needs it has to *depend on* the result, as `if backend != null then ...`
does above, not merely follow it. Get this wrong and `putArtifact()` /
`getArtifact()` throw naming the fix, rather than silently writing to
`spellcraft/false/artifacts/<name>`.

Because both land during evaluation, the value can *shape* the configuration —
choosing how many resources to emit, or which branch to take — not merely appear
inside it. A Terraform data source can only do the latter.

## Provider aliases

`providerAliases(default)` emits an aliased `aws` provider for every region the
account has enabled, with the alias set to the region name, plus an unaliased
default for the region you name. Plugins then take a region as an argument and
bind to `aws.<region>` without any per-spell wiring.

It is also the reason a spell only declares providers once, no matter how many
region-aware plugins it uses.

## The auth passthrough

`aws.auth` re-exports [`@c6fc/spellcraft-aws-auth`](https://www.npmjs.com/package/@c6fc/spellcraft-aws-auth),
so a spell that already imports this module can reach the credential helpers
without a second import:

```jsonnet
{ "identity.json": aws.auth.getCallerIdentity() }
```

<!-- SPELLCRAFT_DOCS_API_START -->
## API Reference

### `bootstrap(project)`

Prepares the S3 backend for a project, creating the bootstrap bucket if it
does not exist yet, and returns the Terraform `backend` block for it.

This is the one function here that writes: it creates the bucket on first
use. State and artifacts for every project live in that one bucket, keyed
by project name.

`getArtifact()` and `putArtifact()` key their object off the project name
this sets, so either one throws if it runs before this has. Jsonnet does
not guarantee that order on its own -- thread this function's result into
whatever calls them, the way `enableServices()` is threaded elsewhere in
this ecosystem, rather than merely calling both in the same manifest.

A spell that only ever bootstraps one project, known ahead of time, can
skip calling this from Jsonnet at all: set `config.spellcraftProject` in
`package.json` and it runs during `init()`, before evaluation starts, so
there's no ordering hazard to think about. The two are mutually
exclusive -- calling this explicitly throws if `config.spellcraftProject`
already bootstrapped the spell, rather than letting the two silently
disagree about which project is live.

A spell has one project. Calling this again with a *different* name in
the same process throws for the same reason -- to read another spell's
state, use `getRemoteState()`, not a second `bootstrap()` call. The
same name twice is a no-op.

- param {string} project - names the state prefix; use one per spell
- returns {object} a Terraform block ready to merge into a `.tf.json` file

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

{ "backend.tf.json": aws.bootstrap("my-project") }

// Returns:
// {
//   "terraform": {
//     "backend": {
//       "s3": {
//         "bucket": "spellcraft-random-0123456789",
//         "key": "spellcraft/my-project/terraform.tfstate",
//         "region": "us-east-1"
//       }
//     }
//   }
// }
```

---
### `getArtifact(name)`

Reads an artifact previously stored by `putArtifact()`.

Artifacts are how one spell hands a value to another without a Terraform
data source — the value is fetched while the manifest evaluates, so it can
shape the configuration rather than only appear in it.

Throws if `bootstrap()` hasn't set a project name yet -- see `bootstrap()`
for why that ordering isn't automatic.

- param {string} name - the artifact name given to `putArtifact()`
- returns {*} the stored value, parsed back from JSON

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

local backend = aws.bootstrap("my-project");
local shared = if backend != null then aws.getArtifact("network") else null;

{ "app.tf.json": { resource: { aws_instance: { app: { subnet_id: shared.subnetId } } } } }
```

---
### `getBootstrapBucket()`

The name of the bootstrap bucket, or `false` when none exists yet.

Discovery is by naming convention rather than by tag, and more than one
match in the account is an error — there is meant to be exactly one.

- returns {string|boolean} the bucket name, or false

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

{ "state.json": { bucket: aws.getBootstrapBucket() } }
```

---
### `getRemoteState(project)`

Reads the Terraform state of another SpellCraft project in the same account.

Use it to consume another spell's outputs at evaluation time. The project
name is the one passed to that spell's `bootstrap()`.

- param {string} project - the other spell's project name
- returns {object} that project's Terraform state

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

local network = aws.getRemoteState("network");

{ "app.tf.json": { output: { vpc: { value: network.outputs.vpc_id.value } } } }
```

---
### `putArtifact(name, content)`

Stores a value as a JSON artifact in the bootstrap bucket, under this
project's prefix. Read it back with `getArtifact()`.

Throws if `bootstrap()` hasn't set a project name yet -- see `bootstrap()`
for why that ordering isn't automatic.

- param {string} name - the artifact name
- param {*} content - any JSON-serialisable value
- returns {boolean} true

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

local backend = aws.bootstrap("my-project");

{
    "backend.tf.json": backend,
    "meta.json": { stored: if backend != null then aws.putArtifact("network", { subnetId: "subnet-abc123" }) else null },
}
```

---
### `providerAliases(default)`

Builds the full set of AWS provider declarations for a spell.

Returns one aliased provider per region your credentials can see — the
alias is the region name, so resources bind to it as `aws.us-west-2` — plus
an unaliased default provider for the region you name. This is what lets
plugins like `@c6fc/spellcraft-aws-s3` take a region as an argument and
place resources in it without every spell wiring providers by hand.

The region list comes from a live `describeRegions` call, so the set
reflects what the account actually has enabled.

- param {string} default - region for the unaliased default provider
- returns {object[]} provider declarations, for the `provider` key of a `.tf.json`

**Examples:**

```jsonnet
local aws = import "@c6fc/spellcraft-aws-terraform/module.libsonnet";

{ "providers.tf.json": { provider: aws.providerAliases("us-east-2") } }

// Returns:
// [
//   { "aws": { "alias": "us-east-1", "region": "us-east-1" } },
//   { "aws": { "alias": "us-west-2", "region": "us-west-2" } },
//   ...
//   { "aws": { "region": "us-east-2" } }
// ]
```

---

<!-- SPELLCRAFT_DOCS_API_END -->

## Development

```bash
npm test        # renders test.jsonnet through a real SpellFrame
npm run doc     # regenerates the API section above from module.libsonnet
```

`npm test` **writes**: it creates the bootstrap bucket if your account has none,
and stores an artifact in it.

## License

MIT © [Brad Woodward](https://github.com/c6fc)
