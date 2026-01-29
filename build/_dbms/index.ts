#!/usr/bin/env bun

//@ts-check

// import type { PathLike } from 'fs'
import { tmpdir } from 'os'
import path from 'node:path'
import fs from 'node:fs/promises'
import fsNode from 'node:fs'
import { Pool } from 'pg'
import * as shelljs from "shelljs"
// import { inspect, promisify } from 'node:util'
// import { exec } from 'child_process'
// import { spawn } from 'node:child_process'


import { stdErrorResultCtors, hasProperValue, success, type Result, stringifyError, stdPromise, failure, resultify, stdErrorCtors, hasValue, stringify } from "@danfortsys/standard"
import { logMessage, styles, logError, logWarning } from "@danfortsys/loggr"

import { tryAppendFile, tryReadFile } from '../_utils'
import { compareSchemas } from './schema-diff'



/** Main build function for the DBMS */
export default async function (destFolderPath: string, options: DbBuildOptions = {}) {
	console.log('Db Build args:', options)

	// Get and validate database url arg from options or process.env
	const dbUrl = options.dbUrl ?? process.env.DATABASE_URL
	if (!hasProperValue(dbUrl)) return stdErrorResultCtors['malformed-input']({
		description: 'Db url not provided as an arg or env variable'
	})

	// Validate destination directory arg
	if (!hasProperValue(destFolderPath)) return stdErrorResultCtors['malformed-input']({
		description: 'Output folder path empty'
	})

	const resetOk = options.dbResetOk ?? false
	const initScriptPath = path.join(destFolderPath, 'db.init.sql') // Always generated output schema init script
	const migraScriptPath = path.join(destFolderPath, 'db.migrate.sql') // Conditionally generated output migration script
	const schemaScriptsFolderRelativePath = "./source/server/dbms"
	const srcMigraScriptPath = path.join(schemaScriptsFolderRelativePath, ".migrate.sql")
	const schemaName = 'public'

	return stdPromise
		.init(resultify(fs.mkdir(destFolderPath, { recursive: true }), stdErrorCtors.internal({
			description: "Error accessing or creating output folder"
		})))

		// remove any existing output scripts
		.then(_ => resultify(Promise.all([initScriptPath, migraScriptPath].map(p => fs.unlink(p).catch(() => { }))), stdErrorCtors.internal({
			description: "Error removing any existing output scripts"
		})))

		// verify schema scripts directory exists
		.then(_ => resultify(fs.access(schemaScriptsFolderRelativePath), stdErrorCtors.internal({
			description: `Schema SQL scripts directory not found at ${schemaScriptsFolderRelativePath}`
		})))

		// get sorted scripts
		.then(_ => resultify(getSortedScriptPaths(schemaScriptsFolderRelativePath), stdErrorCtors.internal({
			description: "Couldn't read sql schema scripts"
		})))

		// ALWAYS generate init script for initializing fresh dbs (e.g., test dbs)
		.then(([_0, _1, _2, sortedSqlPaths]) => {
			logMessage('Generating db init script... ')
			return createInitScriptFile(sortedSqlPaths, initScriptPath).then(_ => _.interpretFailureAs(stdErrorCtors.general({
				description: "Couln't generate database initialization script"
			})))
		})

		// Check if schema has data"
		.then(([]) => {
			logMessage('Done')
			return resultify(schemaHasData(schemaName, dbUrl), stdErrorCtors.internal({
				description: "Couldn't check if schema has data"
			}))
		})
		.then(([_0, _1, _2, sortedSqlPaths, _4, _schemaHasData]) => {
			if (_schemaHasData) {
				logMessage('Target schema has data; needs structural comparison with scripts')

				const tempSchema = `temp_${Date.now()}`

				// Check if existing db matches scripts, i.e., running the scripts on a fresh schema produces the same shape as existing Db
				return stdPromise

					.init(createSchemaFromScripts(sortedSqlPaths, tempSchema, dbUrl))

					.then(_ => { // compare schemas
						// console.log(`Next then() argument after createSchemaFromScripts: ${_}`)
						return resultify(
							compareSchemas({
								dbUrl,
								schema1: [schemaName, "existing Db"],
								schema2: [tempSchema, "current DDL scripts"]
							}),
							{
								errCode: "internal",
								description: `Error comparing Db with scripts`
							})
					})

					.then(([_, diff]) => { // handle comparison
						if (hasValue(diff)) { // Db schema does not match DDL scripts
							logMessage(`Existing Db Schema does not match DDL scripts.`)
							logMessage(`Details: ${styles.italic}${stringify(diff)}${styles.reset}`)
							logMessage(`Checking for migration script...`)

							return resultify(tryReadFile(srcMigraScriptPath))
								.then(async readResult => {
									if (readResult.type === "success") {
										logMessage(`Migration script found at ${srcMigraScriptPath}.`)
										logMessage(`Appending migration script to ${migraScriptPath}...`)
										const migrationScriptPreamble = `SET search_path TO :schema;\n`
										const appendResult = await resultify(
											tryAppendFile(migraScriptPath, `${migrationScriptPreamble}\n${readResult.value}\n`)
										)
										if (appendResult.type === "success") {
											logMessage(`Migration script appended to ${migraScriptPath}`)
											return success(void (0))
										}
										else {
											return appendResult.interpretAs(stdErrorCtors.general({
												description: `Failed to append migration script to ${migraScriptPath}`
											}))
										}
									}
									else { // Migration script not found or unreadable
										logMessage(`Migration script not found/readable at ${styles.italic}${srcMigraScriptPath}${styles.reset}.`)

										if (!isLocalDatabase(dbUrl)) { // Can't reset a remote Db (could be production)
											return stdErrorResultCtors.general({
												description: [
													`Db Schema differs from DDL scripts, but migration script not found.`,
													`Cannot reset remote (possibly prod) database.`
												].join(' ')
											})
										}
										else if (resetOk) { // Db reset is OK
											logMessage(`Migration script not found, but --db-reset-ok specified`)
											return createInitScriptFile(sortedSqlPaths, migraScriptPath)
										}
										else { // Db reset is not OK
											return stdErrorResultCtors.general({
												description: [
													`Db schema differs from DDL scripts, but migration script not found.`,
													`Use --db-reset-ok to allow database reset in development.`
												].join(' ')
											})
										}
									}
								})
						}
						else { // Db schema matches DDL scripts
							logMessage(`Existing Db Schema is compatible with DDL scripts. Nothing to do.`)
							return success(void (0))
						}
					})
					.done()

					.finally(() => { // Always cleanup temp schema, whether or not errors occurred
						execQuery(`DROP SCHEMA IF EXISTS "${tempSchema}" CASCADE;`, dbUrl).catch(cleanupError => {
							logWarning(`Failed to cleanup temp schema ${tempSchema}: ${stringifyError(cleanupError)}`)
						})
					})
			}
			else {
				logMessage('Target schema has no data; can be safely reset')
				return createInitScriptFile(sortedSqlPaths, migraScriptPath)
			}
		})
		.done()

}

/** Type of options for DBMS build function */
interface DbBuildOptions {
	dbUrl?: string
	dbResetOk?: boolean
	[key: string]: any
}

/** Checks if a schema has data in any of its tables.
 * @param {string} schema - The schema name.
 * @param {string} dbUrl - The database connection string.
 * @returns {Promise<boolean>} - Returns true if schema has data.
 */
export async function schemaHasData(schema: string, dbUrl: string) {
	if (!schema) {
		logError('Usage: schemaHasData(schema, dbUrl)')
		return false
	}
	if (!dbUrl) {
		logError('DATABASE_URL must be provided as an argument or environment variable.')
		return false
	}

	// Check if any tables exist in the schema
	const tablesQuery = `SELECT table_name FROM information_schema.tables WHERE table_schema = '${schema}' AND table_type = 'BASE TABLE' LIMIT 5`
	const tables = await execQuery(tablesQuery, dbUrl)

	// If no tables exist, schema is empty
	if (!tables || tables.length === 0) { return false }

	// Check each table for data
	for (const table of tables) {
		const tableName = table.table_name
		const countQuery = `SELECT EXISTS(SELECT 1 FROM "${schema}"."${tableName}" LIMIT 1) as has_rows`
		const result = await execQuery(countQuery, dbUrl)
		if (result?.[0]?.has_rows === true) {
			return true
		}
	}

	return false
}

export function getSortedScriptPaths(scriptsFolderPath: string) {
	return fs.readdir(scriptsFolderPath).then(sqlFiles => sqlFiles
		.filter(fileName => fileName.endsWith('.sql') && fileName !== '.migrate.sql')
		.sort((a, b) => {
			const aNum = parseInt(a.match(/^_?(\d+)/)?.[1] ?? '999')
			const bNum = parseInt(b.match(/^_?(\d+)/)?.[1] ?? '999')
			return aNum - bNum
		})
		.map(file => path.join(scriptsFolderPath, file))
	)
}

/** Generates a full database initialization script from ordered SQL script paths.
 * @param {string[]} orderedScriptPaths - Array of ordered SQL script file paths.
 * @param {string} outputScriptPath - Path to the output script file.
 * @param {string} outputScriptPreamble - Preamble to include at the start of the output script.
 * @returns {Promise<Result<void>>} - A promise that resolves to a Result indicating success or failure.
 */
export async function createInitScriptFile(orderedScriptPaths: string[], outputScriptPath: string): Promise<Result> {
	try {
		// logMessage('Generating schema initialization script')
		const scriptsWithMarkers = await Promise.all(orderedScriptPaths.map(async p => {
			const content = await fs.readFile(p, 'utf8')
			const fileName = path.basename(p)
			return `\n-- FILE: ${fileName}\n-- PATH: ${p}\n${content}`
		}))

		const preamble = `SET search_path TO :schema;`
		fsNode.writeFileSync(outputScriptPath, `${preamble}\n${scriptsWithMarkers.join('\n\n')}\n`)
		// logMessage('Done generating schema initialization script')

		return success(void (0))
	}
	catch (error) {
		return failure(error).interpretAs(stdErrorCtors.general({ description: `Failed to generate Db init script` }))
	}
}

/** Creates and initializes a schema using provided script paths
 * @param {string[]} scriptPaths
 * @param {string} schema
 * @param {string} dbUrl
 */
export function createSchemaFromScripts(orderedScriptPaths: string[], schema: string, dbUrl: string): Promise<Result<unknown>> {
	if (!orderedScriptPaths || !schema || !dbUrl) return Promise.resolve(stdErrorResultCtors['malformed-input']({
		description: 'Usage: createSchemaFromScripts(scriptPaths, schema, dbUrl)'
	}))

	const tempScriptPath = path.join(tmpdir(), `temp-schema-${Date.now()}.sql`)
	// logMessage(`tempScriptPath: ${tempScriptPath}`)

	const ret = (stdPromise

		// Create temporary init script
		.init((logMessage(`Creating init script...`), resultify(createInitScriptFile(orderedScriptPaths, tempScriptPath), stdErrorCtors.general({
			description: `Could not create init script from scripts in ${orderedScriptPaths}`
		}))))

		// Create the schema in the db
		.then(_ => (logMessage(`Creating schema "${schema}"...`), resultify(execQuery(`CREATE SCHEMA "${schema}";`, dbUrl), stdErrorCtors.general({
			description: `Could not create schema ${schema} in the db`
		}))))

		// Initialize schema with the script
		.then(_ => (logMessage(`Initializing schema "${schema}"...`), resultify(execScript(tempScriptPath, schema, dbUrl), stdErrorCtors.general({
			description: `Error executing init script on schema ${schema}`
		}))))

		.then(([_1, _2, _3]) => (logMessage("Done generating schema from scripts"), success()))

		.done()
	)

	ret.finally(() => {
		// logWarning(`Trying to clean up temp file`)
		// Try to clean up temp file
		// fs
		// 	.unlink(tempScriptPath)
		// 	.catch(cleanupError => logWarning(`Failed to cleanup temp script file: ${cleanupError}`))
	})

	return ret
}

/** Executes a SQL query against the database.
 * @param query The SQL query to execute.
 * @param dbUrl The database connection string.
 * @returns A promise that resolves to an array of rows.
 */
export async function execQuery(query: string, dbUrl: string) {
	if (!dbUrl) {
		throw new Error('DATABASE_URL must be provided as an argument.')
	}

	const pool = new Pool({ connectionString: dbUrl })

	try {
		const result = await pool.query(query)
		return result.rows
	}
	catch (error) {
		// console.error('Error executing SQL query:', error)
		throw error
	}
	finally {
		await pool.end()
	}
}

/** Executes a SQL script file against the database.
 * The script should use a :schema variable, e.g., starting with: SET search_path TO :schema;
 * @param {string} scriptPath - Path to the SQL script file.
 * @param {string} schema - Database schema name.
 * @param {string} dbUrl - The database connection string.
 * @returns {Promise<string>} - A promise that resolves to command output.
 */
export function execScript(scriptPath: string, schema: string, dbUrl: string) {
	// const { stderr, stdout } = shelljs.exec(`psql "${dbUrl}" -v ON_ERROR_STOP=1 -v schema='${schema}' -f "${scriptPath}"`)
	return Promise
		.resolve()

		.then(_ => {
			if (hasProperValue(dbUrl) === false) {
				throw new Error('DATABASE_URL must be provided as an argument.')
			}
			else {
				return shelljs.exec(
					`psql "${dbUrl}" \
					-X \
					-P pager=off \
					-v ON_ERROR_STOP=1 \
					-v schema='${schema}' \
					-f "${scriptPath}"`
				)
			}
		})

		.then(({ stderr, stdout }) => {
			if (hasProperValue(stderr)) {
				// logMessage(`Throwing ${stderr} from execScript`)
				throw new Error(stderr)
			}
			else {
				// logMessage(`Returing ${stdout} from execScript`)
				return stdout
			}
		})

	// logWarning(`Stderr from exec psql: ${stringify(stderr)}`)
}

/** Checks if a database URL points to a local database.
 * @param {string} dbUrl - The database connection string.
 * @returns {boolean} - Returns true if the database is local.
 */
export function isLocalDatabase(dbUrl: string): boolean {
	try {
		const url = new URL(dbUrl)
		const hostname = url.hostname.toLowerCase()

		// Check for common local hostnames and IPs
		const localHosts = [
			'localhost',
			'127.0.0.1',
			'::1',
			'0.0.0.0'
		]

		return localHosts.includes(hostname) || hostname.endsWith('.local')
	}
	catch {
		// If URL parsing fails, assume it's remote for safety
		return false
	}
}


