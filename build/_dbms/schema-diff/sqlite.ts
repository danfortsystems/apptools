// import pgStructure, { type Schema, DbObject, Func } from 'pg-structure'
import { sqliteStorageFactory } from "@danfortsys/storage"

import { entries, hasProperValue, intersection, stdErrorResultCtors, Result, success } from "@danfortsys/standard"


/** Compares the structure of two schemas hierarchically
 * @param args Comparison arguments
 * @param args.dbUrl Database connection URL
 * @param args.schema1 First schema (tuple of [name, label])
 * @param args.schema2 Second schema (tuple of [name, label])
 * @returns Structured diff object, or undefined if there are no differences
 * @throws If any argument is missing or schemas not found
 */
export async function compareSchemas(dbPath1: string, dbPath2: string): Promise<Result<SchemaDiff | undefined>> {
	if (!hasProperValue(dbPath1)) return stdErrorResultCtors['bad-input']({ description: 'compareSchemas: Db Path 1 argument missing' })
	if (!hasProperValue(dbPath2)) return stdErrorResultCtors['bad-input']({ description: 'compareSchemas: Db Path 2 argument missing' })

	const schema1 = await introspectSqlite(dbPath1)
	if (schema1.type === "failure") return stdErrorResultCtors['bad-input']({ description: 'compareSchemas: Db Path 1 argument missing' })
	const schema2 = await introspectSqlite(dbPath2)
	if (schema2.type === "failure") return stdErrorResultCtors['bad-input']({ description: 'compareSchemas: Db Path 1 argument missing' })

	const diff = diffSqliteSchemas(schema1.value, schema2.value)
	return success(entries(diff).some(([_, val]) => val.length > 0) ? diff : undefined)
}

export async function introspectSqlite(dbPath: string): Promise<Result<SqliteSchema>> {
	const storageResult = await sqliteStorageFactory({ dbPath })
	if (storageResult.type === "failure") return storageResult
	const db = storageResult.value

	const tablesResult = await db.raw<{ name: string; sql: string }>({
		sql: `SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`,
		params: [],
		returns: "array"
	})
	if (tablesResult.type !== "success") throw new Error(`Failed to get tables: ${tablesResult.error}`)
	const tables = tablesResult.value

	const schema: SqliteSchema = { tables: {} }

	for (const table of tables) {
		const columnsResult = await db.raw<{ name: string; type: string; notnull: number; dflt_value: any; pk: number }>({
			sql: `PRAGMA table_info(?)`,
			params: [table.name],
			returns: "array"
		})
		if (columnsResult.type !== "success") throw new Error(`Failed to get columns for table ${table.name}: ${columnsResult.error}`)
		const columns = columnsResult.value

		const foreignKeysResult = await db.raw<{ from: string; table: string; to: string; on_update: string; on_delete: string }>({
			sql: `PRAGMA foreign_key_list(?)`,
			params: [table.name],
			returns: "array"
		})
		if (foreignKeysResult.type !== "success") throw new Error(`Failed to get foreign keys for table ${table.name}: ${foreignKeysResult.error}`)
		const foreignKeys = foreignKeysResult.value

		const indexesResult = await db.raw<{ name: string; unique: number }>({
			sql: `PRAGMA index_list(?)`,
			params: [table.name],
			returns: "array"
		})
		if (indexesResult.type !== "success") throw new Error(`Failed to get indexes for table ${table.name}: ${indexesResult.error}`)
		const indexes = indexesResult.value

		const indexesWithColumns = await Promise.all(indexes.map(async (idx) => {
			const columnsResult = await db.raw<{ name: string }>({
				sql: `PRAGMA index_info(?)`,
				params: [idx.name],
				returns: "array"
			})
			if (columnsResult.type !== "success") throw new Error(`Failed to get index columns for index ${idx.name}: ${columnsResult.error}`)
			return {
				...idx,
				columns: columnsResult.value.map((c) => c.name),
			}
		}))

		schema.tables[table.name] = {
			sql: table.sql,
			columns: columns.map((c) => ({
				name: c.name,
				type: c.type,
				nullable: !c.notnull,
				default: c.dflt_value,
				primaryKey: c.pk > 0,
			})),
			foreignKeys: foreignKeys.map((fk) => ({
				column: fk.from,
				references: {
					table: fk.table,
					column: fk.to,
				},
				onUpdate: fk.on_update,
				onDelete: fk.on_delete,
			})),
			indexes: indexesWithColumns.map((i) => ({
				name: i.name,
				unique: !!i.unique,
				columns: i.columns,
			})),
		}
	}

	return success(schema)
}
export type SqliteSchema = {
	tables: {
		[tableName: string]: {
			sql?: string
			columns: Array<{
				name: string
				type: string
				nullable: boolean
				default: any
				primaryKey: boolean
			}>
			foreignKeys: Array<{
				column: string
				references: {
					table: string
					column: string
				}
				onUpdate: string
				onDelete: string
			}>
			indexes: Array<{
				name: string
				unique: boolean
				columns: string[]
			}>
		}
	}
}

/** Creates a diff between two input SQLite schema objects */
function diffSqliteSchemas(schema1: SqliteSchema, schema2: SqliteSchema): SchemaDiff {
	const tables1 = Object.keys(schema1.tables || {})
	const tables2 = Object.keys(schema2.tables || {})

	return {
		added: tables2.filter(t => !tables1.includes(t)),
		removed: tables1.filter(t => !tables2.includes(t)),
		changed: (() => {
			return [...intersection([tables1, tables2])]
				.filter(tableName => {
					const table1 = schema1.tables[tableName]!
					const table2 = schema2.tables[tableName]!

					// Compare table SQL
					if (table1.sql !== table2.sql) {
						return true
					}

					// Compare columns
					const cols1 = table1.columns.map((c) => `${c.name}:${c.type}:${!c.nullable}:${c.primaryKey}`)
					const cols2 = table2.columns.map((c) => `${c.name}:${c.type}:${!c.nullable}:${c.primaryKey}`)
					if (!arraysEqual(cols1, cols2)) {
						return true
					}

					// Compare foreign keys
					const fks1 = table1.foreignKeys.map((fk) => `${fk.column}:${fk.references.table}:${fk.references.column}:${fk.onUpdate}:${fk.onDelete}`)
					const fks2 = table2.foreignKeys.map((fk) => `${fk.column}:${fk.references.table}:${fk.references.column}:${fk.onUpdate}:${fk.onDelete}`)
					if (!arraysEqual(fks1, fks2)) {
						return true
					}

					// Compare indexes
					const idx1 = table1.indexes.map((i) => `${i.name}:${i.unique}:${i.columns.join(',')}`)
					const idx2 = table2.indexes.map((i) => `${i.name}:${i.unique}:${i.columns.join(',')}`)
					if (!arraysEqual(idx1, idx2)) {
						return true
					}

					return false
				})
		})(),
	}
}
function arraysEqual(a: string[], b: string[]): boolean {
	if (a.length !== b.length) return false
	for (let i = 0; i < a.length; i++) {
		if (a[i] !== b[i]) return false
	}
	return true
}
type SchemaDiff = {
	added?: string[],
	removed?: string[],
	changed?: string[]
}


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



// type NamedObject = { name: string, type: string }
/** Creates a diff between two input schema objects,
 * starting from major object types like tables, functions, views, etc.
 * and progessively drilling down to columns, functions args, etc.
 */
// function diffSchemas(schema1: Schema, schema2: Schema): SchemaDiff {
// 	const objects1 = dictFromIterable(getAllObjects(schema1), _ => `${singularize(_.type)}: ${_.name}`)
// 	const objects2 = dictFromIterable(getAllObjects(schema2), _ => `${singularize(_.type)}: ${_.name}`)

// 	const keys1 = keys(objects1)
// 	const keys2 = keys(objects2)

// 	return {
// 		added: keys2.filter(k => !keys1.includes(k)),
// 		removed: keys1.filter(k => !keys2.includes(k)),
// 		changed: (() => {

// 			return [...intersection([keys1, keys2])]
// 				.filter(key => {
// 					const obj1 = objects1[key]!
// 					const obj2 = objects2[key]!

// 					assert(isObject(obj1), `obj1 is not an object, it is ${typeof obj1}`)
// 					return ("source" in obj1 && "source" in obj2)
// 						? normalizeSource(String(obj1.source)) !== normalizeSource(String(obj2.source))
// 						: stringify(obj1) !== stringify(obj2)

// 				})
// 			// map(objName => ({ name: objName, type: (k) }))
// 		})(),

// 		/*changed: majorObjectKindsPlural.flatMap(k => {
// 			const objects1 = getObjectsGeneral(schema1, k)
// 			const objects2 = getObjectsGeneral(schema2, k)

// 			return [...intersection([objects1.map(_ => _.name), objects2.map(_ => _.name)])]
// 				.filter(objName => {
// 					// const xx = getObjects(schema1, "functions")
// 					const obj1 = objects1.find(_ => objName === _.name)!
// 					const obj2 = objects2.find(_ => objName === _.name)!

// 					if (objName.toLowerCase().includes("get_users")) {
// 						logWarning(`Processing get users function`)
// 						logWarning(`Source from schema 1: ${normalizeSource((obj1 as Func).source)}`)
// 						logWarning(`Source from schema 2: ${normalizeSource((obj2 as Func).source)}`)
// 					}

// 					return ("source" in obj1 && "source" in obj2)
// 						? normalizeSource(String(obj1.source)) !== normalizeSource(String(obj2.source))
// 						: stringify(obj1) !== stringify(obj2)

// 				}).
// 				map(objName => ({ name: objName, type: (k) }))
// 		})*/
// 	}
// }

// function getAllObjects(schema: Schema) {
// 	return new Set(union(majorObjectKindsPlural.map(k => getObjectsGeneral(schema, k))))
// }
// function getObjects<K extends MajorObjectKindPlural>(schema: Schema, kind: K) {
// 	// const k = `${kind}s` as const
// 	return schema[kind] //as DbObject[]
// }
// function getObjectsGeneral<K extends MajorObjectKindPlural>(schema: Schema, kind: K) {
// 	// const k = `${kind}s` as const
// 	return (schema[kind] as DbObject[]).map(obj => {
// 		const x = { ...obj, type: kind } as DbObject & { type: K }
// 		assert(isObject(x))
// 		return x
// 	})
// }

// type MajorObjectKind = (typeof majorObjectKinds)[number]
// const majorObjectKindsPlural = ["tables", "views", "materializedViews", "functions", "windowFunctions", "aggregateFunctions", "procedures", "types", "sequences"] as const
// type MajorObjectKindPlural = (typeof majorObjectKindsPlural)[number]
// const majorObjectKinds = ["table", "view", "materializedView", "function", "normalFunction", "windowFunction", "aggregateFunction", "procedure", "type", "sequence"] as const
