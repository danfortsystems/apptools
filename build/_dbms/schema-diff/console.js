#!/usr/bin/env node

//@ts-check

import { compareSchemas } from './index.ts'

// CLI usage
const USAGE = 'Usage: schema-diff <db_url> <schema1> <schema2> [schema1_label] [schema2_label]'
const args = process.argv.slice(2)

if (args.length < 3 || args.length > 5) {
	console.error(USAGE)
	process.exit(1)
}

const [dbUrl, schema1, schema2, schema1Label, schema2Label] = args

if (!dbUrl || !schema1 || !schema2) {
	console.error(USAGE)
	process.exit(1)
}

try {
	const result = await compareSchemas({
		dbUrl,
		schema1: [schema1, schema1Label ?? ""],
		schema2: [schema2, schema2Label ?? ""]
	})

	if (result === undefined) {
		// Schemas match - exit with code 0
		process.exit(0)
	}
	else {
		// Schemas differ - output differences and exit with code 1
		const label1 = schema1Label ?? schema1
		const label2 = schema2Label ?? schema2

		const italicWhite = '\x1b[3;37m'
		const reset = '\x1b[0m'

		console.error(`Differences detected between ${label1} and ${label2}`)

		// Output unique objects
		const schema1Objects = result.uniquesBySchema[schema1]
		if (schema1Objects && Object.keys(schema1Objects).length > 0) {
			console.error(`${italicWhite}Objects only in ${label1}:${reset}`)
			for (const [key, objDetails] of Object.entries(schema1Objects)) {
				const type = objDetails?.type ?? key.split(':')[0]
				const name = objDetails?.name ?? key.split(':')[1]
				console.error(`${italicWhite}  - ${type}: ${name}${reset}`)
			}
			// console.error()
		}

		const schema2Objects = result.uniquesBySchema[schema2]
		if (schema2Objects && Object.keys(schema2Objects).length > 0) {
			console.error(`${italicWhite}Objects only in ${label2}:${reset}`)
			for (const [key, objDetails] of Object.entries(schema2Objects)) {
				const type = objDetails?.type ?? key.split(':')[0]
				const name = objDetails?.name ?? key.split(':')[1]
				console.error(`${italicWhite}  + ${type}: ${name}${reset}`)
			}
			// console.error()
		}

		// Output conflicting objects
		if (Object.keys(result.conflictsByObject).length > 0) {
			console.error(`${italicWhite}Objects with conflicting definitions:${reset}`)
			for (const [objName, conflicts] of Object.entries(result.conflictsByObject)) {
				const obj1 = conflicts[schema1]
				const obj2 = conflicts[schema2]
				if (!obj1 || !obj2) continue
				const type = objName.split(':')[0]
				const name = objName.split(':')[1]
				console.error(`${italicWhite}  * ${type}: ${name}${reset}`)

				// Remove type and name from display since they're already shown above
				const { type: _, name: __, ...display1 } = obj1
				const { type: ___, name: ____, ...display2 } = obj2

				console.error(`${italicWhite}      in "${label1}": ${JSON.stringify(display1, null, 8).replace(/\n/g, '\n      ')}${reset}`)
				console.error(`${italicWhite}      in "${label2}": ${JSON.stringify(display2, null, 8).replace(/\n/g, '\n      ')}${reset}`)
			}
		}

		// console.error("abc")
		process.exit(1)
	}
}
catch (error) {
	console.error(`Error: ${error instanceof Error ? error.message : String(error)}`)
	process.exit(1)
}
