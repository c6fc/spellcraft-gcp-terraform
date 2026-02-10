/*
	This file should manifest all the exposed features of your module
	so users can see examples of how they are used, and the output they
	generate.
*/

local gcp = import "module.libsonnet";

{
	"bootstrap.tf.json": gcp.bootstrap("spellcraft-gcp-terraform-module-test"),
	"test.tf.json": {
		output: {
			putArtifact: {
				value: gcp.putArtifact("putArtifactTest", "mytest2")
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
	'providers.tf.json': {
		provider: gcp.providerAliases("us-west2", "us-")
	}
}