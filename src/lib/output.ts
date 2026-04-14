export function printJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

export function printSection(title: string): void {
  process.stdout.write(`\n${title}\n`);
}

export function printKeyValue(label: string, value: string | number | boolean | null | undefined): void {
  process.stdout.write(`${label}: ${value ?? 'n/a'}\n`);
}

export function fail(message: string): never {
  throw new Error(message);
}
