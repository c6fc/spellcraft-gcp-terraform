#! /usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const yargs = require('yargs');
const { hideBin } = require('yargs/helpers');
const { SpellFrame } = require('@c6fc/spellcraft');

const spellframe = new SpellFrame();

// 1. Resolve local package info to simulate a real plugin load
const packageDir = path.resolve(__dirname, '..'); // Assuming script is in /utils
const packageJsonPath = path.join(packageDir, 'package.json');

if (!fs.existsSync(packageJsonPath)) {
    throw new Error(`[!] Could not find package.json at ${packageJsonPath}`);
}

const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'));
const jsEntry = path.join(packageDir, pkg.main || 'index.js');

console.log(`[*] Loading local plugin context: ${pkg.name}`);

// 2. Load the plugin into SpellFrame
// This registers native functions (namespaced) and populates cliExtensions 
// automatically via the _spellcraft_metadata export in module.js
spellframe.loadPlugin(pkg.name, jsEntry);

(async () => {
	
	let cli = yargs(hideBin(process.argv))
		.usage("Syntax: $0 <command> [options]")
		.scriptName("spellcraft")

		.command("generate <filename>", "Generates files from a configuration", (yargsInstance) => {
			return yargsInstance.positional('filename', {
				describe: 'Jsonnet configuration file to consume',
				type: 'string',
				demandOption: true,
			});
		},
		async (argv) => { 
			try {
				await spellframe.init();
				console.log(`[+] Rendering configuration from: ${argv.filename}`);
				await spellframe.render(argv.filename);
				await spellframe.write();
				console.log("[+] Generation complete.");
			} catch (error) {
				console.error(`[!] Error during generation: ${error.message}`);
				process.exit(1);
			}
		});

	// 3. Register CLI extensions found in the loaded plugin
    // These were populated by loadPlugin() reading _spellcraft_metadata
	if (spellframe.cliExtensions && spellframe.cliExtensions.length > 0) {
		spellframe.cliExtensions.forEach((extensionFn) => {
			if (typeof extensionFn === 'function') {
				extensionFn(cli, spellframe);
			}
		});
	}

	cli
		.demandCommand(1, 'You need to specify a command.')
		.recommendCommands()
		.strict()
		.showHelpOnFail(true)
		.help("help")
		.alias('h', 'help')
		.version()
		.alias('v', 'version')
		.epilogue('For more information, consult the SpellCraft documentation.')
		.argv;
})();