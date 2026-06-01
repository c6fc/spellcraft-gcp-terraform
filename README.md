# SpellCraft GCP Integration

[![NPM version](https://img.shields.io/npm/v/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://www.npmjs.com/package/@c6fc/spellcraft-gcp-terraform)
[![License](https://img.shields.io/npm/l/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://opensource.org/licenses/MIT)

This module exposes common constructs for using [SpellCraft](https://github.com/@c6fc/spellcraft) SpellFrames to deploy infrastructure to GCP using Terraform.

```sh
npm install --save @c6fc/spellcraft-gcp-terraform
```

## Features

This module exposes the concept of a bootstrap bucket (functionally a terraform backend), and artifacts which can contain arbitrary data and are stored alongside the terraform state in the bootstrap bucket. The former allows for dynamic configuration of Terraform providers within different environments, while the latter simplifies the storage and use of dynamic configuration details that might be environment dependent.

<!-- SPELLCRAFT_DOCS_CLI_START -->

<!-- SPELLCRAFT_DOCS_CLI_END -->

## SpellFrame 'init()' features

This plugin registers a custom hook during `init()` on the `SpellFrame` instance. It listens to namespaced events from `@c6fc/spellcraft-terraform`:

- **Deferred Service Enablement Registry**: When GCP services are declared in Jsonnet via `enableServices()`, they are not enabled immediately during manifestation. Instead, they are collected in an in-memory registry. When the `@c6fc/spellcraft-terraform:pre-apply` event is fired (right before Terraform runs), all accumulated services are enabled in a single batched GCP API invocation, preventing API latency from slowing down local rendering iterations.

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

# An instance of @c6fc/spellcraft-gcp-auth
gcp.auth;
```

## JavaScript context features

Extends the JavaScript function context with an `gcpterraform` object containing the following keys:

```JSON
{ 
	"projectName": "<contains the name of the project specified by bootstrap()>",
	"bootstrapBucket": "<contains the name for the bootstrap bucket>",
}
```

<!-- SPELLCRAFT_DOCS_API_START -->
## API Reference

### `enableServices(services)`

Registers a list of GCP services/APIs to be enabled. Rather than enabling them immediately (which slows down rendering), this function registers them in an in-memory registry, which is subsequently activated in a single batched call when the `@c6fc/spellcraft-terraform:pre-apply` event triggers.

- param {array} services - Array of service names to enable (e.g. `["orgpolicy.googleapis.com"]`).
- returns {boolean} true

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.enableServices(["orgpolicy.googleapis.com"]);
```

---
### `bootstrap(project)`

Creates a Terraform backend bucket if one doesn't already exist, then
returns a 'backend' object referencing this bucket and a unique path
for this project's state and artifacts.

- param {string} project
- returns {object} backend

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.bootstrap("myBootstrapTest");

// Returns:
{
   "terraform": {
       "backend": {
           "gcs": {
               "bucket": "spellcraft-random-0123456789",
               "key": "spellcraft/myBootstrapTest/terraform.tfstate",
           }
       }
   }
}
```

---
### `getArtifact(name)`

Obtains the contents of a named artifact stored alongside this project in the bootstrap
bucket. This artifact is created with 'putArtifact';

- param {string} name
- returns {object} backend

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.getArtifact("myArtifact");

// Returns:
<contents of your artifact>
```

---
### `getBootstrapBucket()`

Attempts to discover the bucket created through bootstrap(), returning the
bucket name if present.

- returns {string} bucketArn

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.getBootstrapBucket();

// Returns:
spellcraft-terraform-<project-id>
```

---
### `getRemoteState(project)`

Read the Terraform state for an adjacent SpellCraft project in the same GCP account

- param {string} project
- returns {object} state

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.getRemoteState("mySecondProject");

// Returns:
{ full remote state object }
```

---
### `putArtifact(name, content)`

Stores the JSON-encoded balue of 'contents' as a file in the GCS backend bucket using
the project prefix.

- param {string} name
- param {*} contents
- returns {boolean} true

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.putArtifact("myArtifact", { someData: someValue });

// Returns:
true
```

---
### `googleOrgProject(name, region, map)`

Creates a given folder and project hierarchy in GCP and returns the set of Terraform resources (folders, projects, IAM policies, service accounts, custom roles, etc.).

- param {string} name - The anchor name for the organization hierarchy.
- param {string} region - The default region.
- param {object} map - The tree structure defining folders and projects (see `test.jsonnet` for full schema/example).

#### Dependency & Ordering Features:
- **Service Enablement Ordering:** Resources created within a project (e.g., service accounts, custom roles, IAM policies) automatically receive a `depends_on` targeting that project's service activation resources (`terraform_data.<project-name>-service-depends`). This guarantees they wait until the project's APIs/services are enabled.
- **Post-Everything Dependency:** An automatic `terraform_data.<name>-org-complete` resource is generated. It has a `depends_on` array containing every resource created in the module hierarchy. You can use this to create manual dependencies in your own files:
  ```jsonnet
  my_resource: {
      depends_on: ["terraform_data.test-org-complete"]
  }
  ```

---
### `providerAliases(default, filter="")`

Stores the JSON-encoded value of 'contents' as a file in the GCS backend bucket using
the project prefix. If 'filter' is provided, only region names that string match
will be included.

- param {string} default
- param {string} filter

**Examples:**

```jsonnet
local gcp = import "@c6fc/spellcraft-gcp-terraform";

gcp.providerAliases("us-west2");

// Returns:
[{ google: {
	region: "us-west2"
}}, { google: {
	region: "us-east1",
	alias: "us-east1"
}}, ...]
```

---

<!-- SPELLCRAFT_DOCS_API_END -->


## Installation

Install the plugin as a dependency in your SpellCraft project:

```bash
npm install --save @c6fc/spellcraft-gcp-terraform
```

Once installed, you can load the module into your JSonnet files.

```jsonnet
local aws = import "@c6fc/spellcraft-gcp-terraform";

{
	'backend.tf.json': aws.bootstrap("myProjectName"),

	// Generate provider list defaulting to 'us-west2' but including all 'us-' regions
	'provider.tf.json': {
		provider: aws.providerAliases("us-west2", "us-")
	}
}
```