# SpellCraft AWS Integration

[![NPM version](https://img.shields.io/npm/v/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://www.npmjs.com/package/@c6fc/spellcraft-gcp-terraform)
[![License](https://img.shields.io/npm/l/@c6fc/spellcraft-gcp-terraform.svg?style=flat)](https://opensource.org/licenses/MIT)

This module exposes common constructs for using [SpellCraft](https://github.com/@c6fc/spellcraft) SpellFrames to deploy infrastructure to AWS using Terraform.

```sh
npm install --save @c6fc/spellcraft-gcp-terraform
```

## Features

This module exposes the concept of a bootstrap bucket (functionally a terraform backend), and artifacts which can contain arbitrary data and are stored alongside the terraform state in the bootstrap bucket. The former allows for dynamic configuration of Terraform providers within different environments, while the latter simplifies the storage and use of dynamic configuration details that might be environment dependent.

<!-- SPELLCRAFT_DOCS_CLI_START -->

<!-- SPELLCRAFT_DOCS_CLI_END -->

## SpellFrame 'init()' features

This plugin does not perform any distinct 'init' operations, other than to initialize credentials within the dependant plugin `@c6fc/terraform-gcp-auth`.

## JavaScript context features

Extends the JavaScript function context with an `awsterraform` object containing the following keys:

```JSON
{ 
	"projectName": "<contains the name of the project specified by bootstrap()>",
	"bootstrapBucket": "<contains the ARN for the bootstrap bucket>",
	"bootstrapLocation": "<contains the region where the bootstrap bucket is located>"
}
```

<!-- SPELLCRAFT_DOCS_API_START -->
## API Reference

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