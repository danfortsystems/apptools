#!/usr/bin/env bun

// Main build script, intended to run from root of project

// Usage:
//
// 1. Full (type-check & bundle app code; generate db migration script):
// ./tools/_run.sh build [--dest <artifacts directory>] [--db-url <db connection url>] [--db-reset-ok]
//
// 2. Db only (Generate db migration script):
// ./tools/_run.sh build --only db [--dest <artifacts directory>] [--db-url <db connection url>] [--db-reset-ok]
//
// 3. App only (type-check & bundle app code; db-related args ignored):
// ./tools/_run.sh build --only app [--dest <artifacts directory>]


//@ts-check

import { parseArgs } from "util"
import { argv } from 'process'

import { build as esBuild } from 'esbuild'
import globals from "@esbuild-plugins/node-globals-polyfill"
import modules from "@esbuild-plugins/node-modules-polyfill"

import { ok, resultify, stdErrorResultCtors, stdPromise, stringify, stringifyError, success } from '@danfortsys/standard'
import { logErrorHeader, logMessageHeader } from '@danfortsys/loggr'

import { execShellAsync, hasProperValue } from './_utils'
import { default as buildDB } from "./_dbms"


await (function main() {

	return stdPromise
		.init(resultify(() => extractValidArgs(process.argv.slice(2)))())

		// Type check
		.then(([{ destPath, dbUrl, dbResetOk, only }]) => {
			logMessageHeader(`Build started with args: ${stringify({ destPath, dbUrl, dbResetOk, only })}`)
			return only === 'db' ? ok()
				: runBuildAction("Type-checking", `pnpm exec tsc --noEmit --pretty`)
		})

		// Create output directories
		.then(([{ destPath, dbUrl, dbResetOk, only }, _]) => runBuildAction("Creating directories", `mkdir -p ${destPath}/public`))

		// Copy static client files
		.then(([{ destPath, dbUrl, dbResetOk, only }, _]) => only === 'db' ? ok()
			: runBuildAction("Staging static files", `cp -R ./source/client/static/* ${destPath}/public/`)
		)

		// Build client-side code
		.then(([{ destPath, dbUrl, dbResetOk, only }, _]) => only === 'db' ? ok()
			: runBuildAction("Building client", _ => resultify(esBuild({
				entryPoints: ['./source/client/pages/**/_*.tsx'],
				outdir: `${destPath}/public`,

				// Flatten output by using just the file name
				entryNames: '[name]',

				// ES module format to support tree-shaking
				format: 'esm',

				// Target modern JS for smaller bundles
				target: 'es2020',

				bundle: true,
				platform: 'browser',
				sourcemap: process.env.NODE_ENV !== 'prod',

				// Aggressively optimize & compress code
				minify: true,

				// Preserve names of functions & classes during minification
				keepNames: true,

				// Split dynamic import modules into separate chunks
				splitting: true,

				// Enable aggressive tree-shaking
				treeShaking: true,

				jsxFactory: 'createElement',
				jsxFragment: 'Fragment',

				plugins: [
					// Polyfills Node.js globals like `process`, if needed
					globals(),
					// Polyfills Node.js modules like `path`, `buffer`, etc.
					modules(),
				],
				define: {
					'process.env.NODE_ENV': `"${process.env.NODE_ENV || 'development'}"`
				}
			})))
		)

		// Build server-side code
		.then(([{ destPath, dbUrl, dbResetOk, only }, _]) => only === 'db' ? ok()
			: runBuildAction("Building server", _ => resultify(esBuild({
				entryPoints: ['./source/server/console.ts'],
				outfile: `${destPath}/server.bundle.js`,
				bundle: true,
				format: 'cjs',
				target: 'node22',
				platform: 'node',
				sourcemap: process.env.NODE_ENV !== 'prod',
				external: ['pg-native', 'request', 'yamlparser', 'bun:sqlite'],
				define: { 'process.env.NODE_ENV': '"production"' }
			})))
		)

		// Build database
		.then(([{ destPath, dbUrl, dbResetOk, only }, _]) => only === 'app' ? ok()
			: runBuildAction("Building Db", () => buildDB(destPath, { dbUrl, dbResetOk }))
		)

		// Create version/commit-id file
		/*writeFileSync(path.join(destPath, 'version.json'), stringify({
			version: '1.0.0',
			buildDate: new Date().toISOString()
		}))*/

		.done()

		.then(buildResult => buildResult.type === "failure"
			? (/*logWarning(stringifyError(buildResult.error)),*/ logErrorHeader(`Build Failed`), process.exit(1))
			: (logMessageHeader('Build Completed Successfully'))
		)
		.catch(error => {
			logErrorHeader(stringifyError(error))
			process.exit(1)
		})

})()


/** Parse/Validate/Extract arguments */
function extractValidArgs(rawArgs = argv.slice(2)) {
	const { values: { dest: destPath, "db-url": dbUrl, "db-reset-ok": dbResetOk, only }, positionals } = (() => {
		try {
			const result = parseArgs({
				args: rawArgs,
				options: {
					dest: {
						type: "string",
						default: "./dist",
					},
					"db-url": {
						type: 'string',
						default: process.env.DATABASE_URL,
					},
					"db-reset-ok": {
						type: 'boolean',
						default: false,
					},
					only: {
						type: 'string',
					}
				},

				// Enforce strict argument parsing
				strict: true,

				// Allow positional arguments
				allowPositionals: false
			})

			// Validate only parameter if provided
			if (result.values.only && result.values.only !== 'app' && result.values.only !== 'db') {
				throw new Error(`Invalid --only value: ${result.values.only}. Must be 'app' or 'db'`)
			}

			return result
		}
		catch (error) {
			throw new Error([
				`Error parsing arguments: ${stringifyError(error)}`,
				'Usage: build --dest <artifacts folder path> [--db-url url] [--db-reset-ok] [--only app|db]'
			].join('\n'))
		}
	})()

	return { destPath, dbUrl, dbResetOk, only }
}

/** Run build action
 * @param {string} heading Header log message
 * @param {BuildAction} action Action to perform
 * @returns {Promise<import("@danfortsys/standard").Result<any>>}
 */
async function runBuildAction(heading, action) {
	console.log(`${heading}...`)

	/** @type {() => Promise<import("@danfortsys/standard").Result<any, import("@danfortsys/standard").StdError>>} */
	const fn = ((typeof action === 'string')
		? () => Promise.resolve(execShellAsync(action))
			.then(_ => success())
			.catch(err => stdErrorResultCtors.general({
				description: stringifyError(err)
			}))

		: action
	)

	return fn().then(result => (result.type === "success"
		? console.log(`Done ${heading}`)
		: console.error([`${heading} failed`, stringifyError(result.error)]
			.filter(hasProperValue).join(': ')),

		result
	))
}

/** @typedef {string | ((...args: any[]) => Promise<import("@danfortsys/standard").Result>)} BuildAction */


/*function getLogFilePath() {
	const timestamp = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').split('.')[0]
	mkdirSync(path.resolve('./logs/build'), { recursive: true })
	return path.resolve(`./logs/build/${timestamp}.log`)
}*/