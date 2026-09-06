/*
	This file should manifest all the exposed features of your module
	so users can see examples of how they are used, and the output they
	generate.
*/

local aws = import "module.libsonnet";

// putArtifact() keys its object off the project name bootstrap() sets, and
// Jsonnet doesn't guarantee bootstrap() runs first just because it's written
// first -- binding it to a local and depending on that value (below) is what
// actually forces the order.
local bootstrap = aws.bootstrap("spellcraft-aws-terraform-module-test");

{
	"bootstrap.tf.json": bootstrap,
	"test.tf.json": {
		output: {
			putArtifact: {
				value: if bootstrap != null then aws.putArtifact("putArtifactTest", "mytest2") else null
			},
			getBootstrapBucket: {
				value: aws.getBootstrapBucket()
			},

			/* These can only be used after the project is created and the contents populated.
			getArtifact: {
				value: aws.getArtifact("putArtifactTest")
			},
			getRemoteState: {
				value: aws.getRemoteState("spellcraft-aws-terraform-module-test")
			}
			*/
		}
	},
	'providers.tf.json': {
		provider: aws.providerAliases("us-west-2")
	}
}