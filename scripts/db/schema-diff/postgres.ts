import pgStructure, { type Schema, DbObject } from 'pg-structure'

import { entries, hasProperValue, intersection, isObject, keys, dictFromIterable, stringify, union, singularize } from "@danfortsys/standard"


/** Compares the structure of two schemas hierarchically
 * @param args Comparison arguments
 * @param args.dbUrl Database connection URL
 * @param args.schema1 First schema (tuple of [name, label])
 * @param args.schema2 Second schema (tuple of [name, label])
 * @returns Structured diff object, or undefined if there are no differences
 * @throws If any argument is missing or schemas not found
 */
export function compareSchemas(args: { dbUrl: string, schema1: SchemaLabeled, schema2: SchemaLabeled }): Promise<SchemaDiff | undefined> {
	const { dbUrl, schema1: [schema1Name, schema1Label], schema2: [schema2Name, schema2Label] } = args

	return pgStructure(dbUrl, { includeSchemas: [schema1Name, schema2Name, "post_gis", "bt_gist"] })
		.then(db => {
			if (!hasProperValue(dbUrl)) { throw new Error('compareSchemas: Database URL argument is empty') }
			if (!hasProperValue(schema1Name)) { throw new Error('compareSchemas: Schema 1 name argument is empty') }
			if (!hasProperValue(schema2Name)) { throw new Error('compareSchemas: Schema 2 name argument is empty') }

			const s1 = db.schemas.get(schema1Name)
			const s2 = db.schemas.get(schema2Name)
			if (!s1) { throw [new Error(`Schema '${schema1Name}' not found in database`)] }
			if (!s2) { throw [new Error(`Schema '${schema2Name}' not found in database`)] }

			const diff = diffSchemas(s1, s2/*, schema1Name, schema2Name*/)
			return entries(diff).some(([_, val]) => val.length > 0) ? diff : undefined
		})
		.catch(e => { throw new Error(`Error diffing schemas`, { cause: e }) })
}
type SchemaLabeled = [name: string, label: string]

/** Creates a diff between two input schema objects, 
 * starting from major object types like tables, functions, views, etc.
 * and progessively drilling down to columns, functions args, etc. 
 */
function diffSchemas(schema1: Schema, schema2: Schema): SchemaDiff {
	const objects1 = dictFromIterable(getAllObjects(schema1), _ => `${singularize(_.type)}: ${_.name}`)
	const objects2 = dictFromIterable(getAllObjects(schema2), _ => `${singularize(_.type)}: ${_.name}`)

	const keys1 = keys(objects1)
	const keys2 = keys(objects2)

	return {
		added: keys2.filter(k => !keys1.includes(k)),
		removed: keys1.filter(k => !keys2.includes(k)),
		changed: (() => {

			return [...intersection([keys1, keys2])]
				.filter(key => {
					const obj1 = objects1[key]!
					const obj2 = objects2[key]!

					assert(isObject(obj1), `obj1 is not an object, it is ${typeof obj1}`)
					return ("source" in obj1 && "source" in obj2)
						? normalizeSource(String(obj1.source)) !== normalizeSource(String(obj2.source))
						: stringify(obj1) !== stringify(obj2)

				})
			// map(objName => ({ name: objName, type: (k) }))
		})(),

		/*changed: majorObjectKindsPlural.flatMap(k => {
			const objects1 = getObjectsGeneral(schema1, k)
			const objects2 = getObjectsGeneral(schema2, k)

			return [...intersection([objects1.map(_ => _.name), objects2.map(_ => _.name)])]
				.filter(objName => {
					// const xx = getObjects(schema1, "functions")
					const obj1 = objects1.find(_ => objName === _.name)!
					const obj2 = objects2.find(_ => objName === _.name)!

					if (objName.toLowerCase().includes("get_users")) {
						logWarning(`Processing get users function`)
						logWarning(`Source from schema 1: ${normalizeSource((obj1 as Func).source)}`)
						logWarning(`Source from schema 2: ${normalizeSource((obj2 as Func).source)}`)
					}

					return ("source" in obj1 && "source" in obj2)
						? normalizeSource(String(obj1.source)) !== normalizeSource(String(obj2.source))
						: stringify(obj1) !== stringify(obj2)

				}).
				map(objName => ({ name: objName, type: (k) }))
		})*/
	}
}

function getObjects<K extends MajorObjectKindPlural>(schema: Schema, kind: K) {
	// const k = `${kind}s` as const
	return schema[kind] //as DbObject[]
}
function getObjectsGeneral<K extends MajorObjectKindPlural>(schema: Schema, kind: K) {
	// const k = `${kind}s` as const
	return (schema[kind] as DbObject[]).map(obj => {
		const x = { ...obj, type: kind } as DbObject & { type: K }
		assert(isObject(x))
		return x
	})
}
function getAllObjects(schema: Schema) {
	return new Set(union(majorObjectKindsPlural.map(k => getObjectsGeneral(schema, k))))
}


type MajorObjectKind = (typeof majorObjectKinds)[number]
const majorObjectKindsPlural = ["tables", "views", "materializedViews", "functions", "windowFunctions", "aggregateFunctions", "procedures", "types", "sequences"] as const
type MajorObjectKindPlural = (typeof majorObjectKindsPlural)[number]
const majorObjectKinds = ["table", "view", "materializedView", "function", "normalFunction", "windowFunction", "aggregateFunction", "procedure", "type", "sequence"] as const

const objectKindTree = [
	["table", [
		"column",
		"indexe",
		"trigger",
		"constraint",
		"exclusionConstraint",
		"uniqueConstraint",
		"foreignKey"
	]],
	"sequence",
	"view", "materializedView",
	"function", "normalFunction", "windowFunction", "aggregateFunction",
	"procedure",
	"type"
]

type SchemaDiff = {
	added?: string[],
	removed?: string[],
	changed?: string[]
}

type NamedObject = { name: string, type: string }



/** Normalizes function source by removing schema-specific qualifiers for comparison */
function normalizeSource(source: string): string {
	if (!source) return source

	// Remove schema qualifiers from type names (e.g., "temp_123.jsonb_array" -> "jsonb_array")
	// This regex matches schema_name.type_name patterns
	return source.replace(/\b[a-zA-Z_][a-zA-Z0-9_]*\./g, '')
}

/** Removes schema prefixes from identifiers, being careful to preserve quoted strings
 * Schema prefixes are removed from unqualified identifiers like:
 * - temp_123.function_name() -> function_name()
 * - temp_123.type_name -> type_name
 * But NOT from quoted strings like 'text' or 'active'
 */
function removeSchemaPrefix(value: any): any {
	if (typeof value !== 'string') return value

	// Don't modify quoted strings (typically string literals)
	if (value.startsWith("'") && value.endsWith("'")) {
		return value
	}

	// Remove schema prefixes from unqualified identifiers
	// This matches patterns like "schema_name.identifier" and replaces with "identifier"
	return value.replace(/\b[a-zA-Z_][a-zA-Z0-9_]*\./g, '')
}