import { promisify } from 'util'
import { appendFile, existsSync, mkdirSync, readFile, writeFile } from 'fs'

export function ensureDir(dirPath: string): void { if (!existsSync(dirPath)) { mkdirSync(dirPath, { recursive: true }) } }
export function tryReadFile(path: string): Promise<string> { return promisify(readFile)(path).then(_ => _.toString('utf8')) }
export function tryWriteFile(path: string, content: string): Promise<void> { return promisify(writeFile)(path, content) }
export function tryAppendFile(path: string, content: string): Promise<void> { return promisify(appendFile)(path, content) }

/** Print an error and exit */
export function exitWithError(msg: string) {
	console.error(msg)
	process.exit(1)
}


export function assert(value: unknown, message?: string): asserts value {
	if (!value) {
		throw new Error(message ?? "Assertion failed")
	}
}
export function hasProperValue<T>(value?: T | null | undefined | undefined): value is T {
	switch (typeof value) {
		case "number":
			return hasValue(value) && Number.isNaN(value) === false
		case "string":
			return hasValue(value) && value.trim().length > 0 && !/^\s*$/.test(value)
		default:
			return hasValue(value)
	}
}
export function hasValue<T>(value?: T | null | undefined | void): value is T {
	return value !== null && value !== undefined
}
export function unique<T>(items: Array<T>): Array<T> {
	return [...new globalThis.Set(items).values()]
}
