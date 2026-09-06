# @c6fc/spellcraft-gcp-terraform

GCS state backend, remote state, artifacts, provider aliases and whole
organization trees for [SpellCraft](https://github.com/c6fc/spellcraft).

[![NPM version](https://img.shields.io/npm/v/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://www.npmjs.com/package/@c6fc/spellcraft-gcp-terraform)
[![License](https://img.shields.io/npm/l/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://opensource.org/licenses/MIT)

This is the GCP half of the Terraform story: it decides where state lives, hands
one spell the values another produced, declares the providers that region-aware
plugins bind to, and builds folder and project hierarchies from a single nested
description. `@c6fc/spellcraft-terraform` runs the apply; this tells it what to
apply against.

```bash
npm install --save @c6fc/spellcraft-gcp-terraform @c6fc/spellcraft-terraform
```

## A complete spell

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

{
	// State backend, and the bucket to hold it. Created on first use.
	"backend.tf.json": gcp.bootstrap("my-project"),

	// One aliased provider per region, plus an unaliased default.
	"providers.tf.json": {
		provider: gcp.providerAliases("us-west2", {}, "us-"),
	},
}
```

```bash
npx spellcraft terraform-apply manifest.jsonnet
```

## Solving stage zero

Terraform cannot enable the API that a resource it is creating depends on — the
provider needs it live before it can plan. That is normally a README step
somebody forgets on the second environment.

This plugin removes the step. As the manifest evaluates, every service the
configuration will need is registered; then it listens for
`@c6fc/spellcraft-terraform:pre-apply` and enables the whole set in one call,
before Terraform starts. The two plugins know nothing about each other — they
meet on the event.

That handshake is why `googleOrgProject()` can create projects and populate them
in a single apply.

## Organization and project trees

`googleOrgProject(name, region, map)` takes one nested description and emits the
folders, projects, service accounts, IAM bindings and API activations to build
it, with the dependency ordering already wired:

```jsonnet
{
	"org.tf.json": gcp.googleOrgProject("platform", "us-west2", {
		type: "folder",
		name: "engineering",
		children: [
			{ type: "folder", name: "production", children: [
				{ type: "project", name: "api" },
			] },
			{ type: "project", name: "sandbox" },
		],
	}),
}
```

The root's parent defaults to the organization your current project belongs to;
set `parent` on the map to place it somewhere else. `test.jsonnet` in this
package is the fully worked example, covering IAM members and per-project
services.

## The bootstrap bucket

`bootstrap(project)` returns the Terraform `backend` block and creates the
bucket behind it if needed. There is one bucket per project —
`spellcraft-terraform-<project-id>` — and `project` becomes the key prefix
separating one spell's state from another's.

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

Both resolve while the manifest evaluates, so a value can *shape* the
configuration rather than only appear in it. `getArtifact()`/`putArtifact()`
use *this* spell's own project — the one passed to `bootstrap()` — so
`bootstrap()` has to run first:

```jsonnet
local network = gcp.getRemoteState("network");

local backend = gcp.bootstrap("my-project");

{
	"backend.tf.json": backend,
	"meta.json": { ok: if backend != null then gcp.putArtifact("build", { image: "app:1.4.2" }) else null },
}
```

```jsonnet
local build = gcp.getArtifact("build");
```

Jsonnet evaluates lazily and in no guaranteed field order, so merely calling
`bootstrap()` somewhere in the manifest doesn't make it run before
`putArtifact()`/`getArtifact()` elsewhere in the same manifest — the call that
needs it has to *depend on* the result, as `if backend != null then ...` does
above, not merely follow it. Get this wrong and `putArtifact()`/`getArtifact()`
throw naming the fix, rather than silently writing to
`spellcraft/null/artifacts/<name>.json`.

## Provider aliases

`providerAliases(default, options, filter)` emits an aliased `google` provider
per Compute region, with the alias set to the region name, plus an unaliased
default. `options` is merged into every declaration — a shared `project` or
`billing_project` goes there — and `filter` keeps only regions whose name
contains it, which is how you avoid declaring forty providers to use two.

## The auth passthrough

`gcp.auth` re-exports [`@c6fc/spellcraft-gcp-auth`](https://www.npmjs.com/package/@c6fc/spellcraft-gcp-auth),
so a spell that already imports this module can reach the credential helpers
without a second import:

```jsonnet
{ "org.json": { domain: gcp.auth.getProjectMetadata().organizationDomain } }
```

<!-- SPELLCRAFT_DOCS_API_START -->
## API Reference

### `bootstrap(project)`

Prepares the GCS backend for a spell, creating the bootstrap bucket if it
does not exist yet, and returns the Terraform `backend` block for it.

This is the one function here that writes: it creates the bucket on first
use. State and artifacts for every spell live in that bucket, keyed by the
name you pass.

`getArtifact()` and `putArtifact()` key their object off the project name
this sets, so either one throws if it runs before this has. Jsonnet does
not guarantee that order on its own -- thread this function's result into
whatever calls them, rather than merely calling both in the same manifest.

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
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

{ "backend.tf.json": gcp.bootstrap("my-project") }

// Returns a terraform.backend.gcs block pointing at the bootstrap bucket,
// prefixed with the project name you passed.
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
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

local backend = gcp.bootstrap("my-project");
local shared = if backend != null then gcp.getArtifact("network") else null;

{ "app.tf.json": { output: { subnet: { value: shared.subnet } } } }
```

---
### `getBootstrapBucket()`

The name of the bootstrap bucket for the current project.

- returns {string} the bucket name, `spellcraft-terraform-<project-id>`

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

{ "state.json": { bucket: gcp.getBootstrapBucket() } }
```

---
### `getRemoteState(project)`

Reads the Terraform state of another SpellCraft spell in the same GCP
project. Use it to consume another spell's outputs at evaluation time; the
name is the one passed to that spell's `bootstrap()`.

- param {string} project - the other spell's project name
- returns {object} that spell's Terraform state

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

local network = gcp.getRemoteState("network");

{ "app.tf.json": { output: { subnet: { value: network.outputs.subnet.value } } } }
```

---
### `googleOrgProject(name, region, map)`

Builds a whole folder and project tree from one nested description.

Each node is a `{ type: "folder" | "project", name, children }`, and may
carry `iam_members`, `services` and the other per-node settings the tree
understands. The root's parent defaults to the organization the current
project belongs to; set `parent` on the map to place it elsewhere.

Alongside the resources it emits the dependency wiring that makes creation
order correct, and registers the services each project needs so they are
enabled before `terraform apply` runs.

`test.jsonnet` in this package is the fully worked example.

- param {string} name - prefix for the generated Terraform resource names
- param {string} region - region for the providers the tree exposes
- param {object} map - the root node of the folder/project tree
- returns {object} Terraform `resource` and `output` blocks

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

{ "org.tf.json": gcp.googleOrgProject("platform", "us-west2", {
    type: "folder",
    name: "engineering",
    children: [{ type: "project", name: "sandbox" }],
  }) }
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
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

local backend = gcp.bootstrap("my-project");

{
    "backend.tf.json": backend,
    "meta.json": { stored: if backend != null then gcp.putArtifact("myArtifact", { someData: someValue }) else null },
}
```

---
### `providerAliases(default, options, filter="")`

Builds the full set of Google provider declarations for a spell.

Returns one aliased provider per Compute region — the alias is the region
name, so resources bind to it as `google.us-west2` — plus an unaliased
default for the region you name. `options` is merged into every provider,
which is where a shared `project` or `billing_project` belongs. Pass a
`filter` to keep only regions whose name contains it.

The region list comes from a live `compute.v1.regions.list` call.

- param {string} default - region for the unaliased default provider
- param {object} options - merged into every provider declaration
- param {string} [filter=""] - substring the region name must contain
- returns {object[]} provider declarations, for the `provider` key of a `.tf.json`

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform/module.libsonnet";

gcp.providerAliases("us-west2", {},  "us-");

// Returns:
// [
//   { "google": { "alias": "us-east1", "region": "us-east1" } },
//   { "google": { "alias": "us-west2", "region": "us-west2" } },
//   ...
//   { "google": { "region": "us-west2" } }
// ]
```

---

<!-- SPELLCRAFT_DOCS_API_END -->

## Development

```bash
npm test        # renders test.jsonnet through a real SpellFrame
npm run doc     # regenerates the API section above from module.libsonnet
```

`npm test` **writes**: it creates the bootstrap bucket if the project has none,
stores an artifact, and enables APIs on the active project.

## License

MIT © [Brad Woodward](https://github.com/c6fc)
