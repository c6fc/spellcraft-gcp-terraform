'use strict';

/*
    This is a pre-written test-case wrapper
    for local module development. Populate
    ../test.jsonnet with tests of your
    module capabilities.

    Run with `npm run test`
*/

const fs = require('fs');
const path = require('path');
const { SpellFrame } = require('@c6fc/spellcraft');

const spellframe = new SpellFrame();

(async () => {
    try {
        // 1. Read the local package.json
        const packageJsonPath = path.resolve('./package.json');
        if (!fs.existsSync(packageJsonPath)) {
            throw new Error("Could not find package.json in current directory.");
        }
        const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'));

        // 2. Identify the entry point
        const jsEntry = path.resolve(pkg.main || 'index.js');

        console.log(`[*] Manually loading plugin: ${pkg.name}`);

        // 3. Register the plugin using the current package name. 
        // This ensures the native functions are registered as "@scope/pkg:func", 
        // matching the std.native() calls in your libsonnet.
        spellframe.loadPlugin(pkg.name, jsEntry);

        // 4. Initialize
        await spellframe.init();

        // 5. Render
        // Note: Ensure your test.jsonnet imports "./module.libsonnet" directly
        console.log("[*] Rendering test.jsonnet...");
        await spellframe.render("test.jsonnet");

        console.log(JSON.stringify(spellframe.lastRender, null, 4));

    } catch (error) {
        console.error(`[!] Test failed: ${error.message}`);
        if (error.stack) console.error(error.stack);
        process.exit(1);
    }
})();