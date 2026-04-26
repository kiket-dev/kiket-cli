import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { migrateWorkflowConfigYaml, parseWorkflow, validateGraph } from '@kiket/engine';

export interface InitResult {
  root: string;
  created: string[];
  skipped: string[];
}

export interface MigrationResult {
  path: string;
  changed: boolean;
  written: boolean;
  changes: string[];
  warnings: string[];
}

const CONFIG_DIRS = [
  '.kiket',
  '.kiket/workflows',
  '.kiket/checks',
  '.kiket/evidence',
  '.kiket/reports',
  '.kiket/dashboards',
  '.kiket/policies',
  '.kiket/templates',
  '.kiket/simulations',
];

const STARTER_WORKFLOW = `model_version: "2.0"
process:
  id: monitored-process
  name: Monitored Process
  version: "2.0"
  description: Starter process configuration for operational compliance monitoring.
workflow:
  id: monitored-process-flow
  name: Monitored Process Flow
  version: "2.0"
states:
  intake:
    type: initial
    metadata:
      label: Intake
  review:
    type: active
    metadata:
      label: Review
  complete:
    type: final
    metadata:
      label: Complete
transitions:
  - from: intake
    to: review
  - from: review
    to: complete
`;

export async function initConfig(root: string, force = false): Promise<InitResult> {
  const created: string[] = [];
  const skipped: string[] = [];

  for (const dir of CONFIG_DIRS) {
    const absolute = path.join(root, dir);
    await mkdir(absolute, { recursive: true });
    created.push(dir);
  }

  const workflowPath = path.join(root, '.kiket/workflows/monitored-process.yaml');
  const exists = await pathExists(workflowPath);
  if (exists && !force) {
    skipped.push('.kiket/workflows/monitored-process.yaml');
  } else {
    await writeFile(workflowPath, STARTER_WORKFLOW, 'utf8');
    created.push('.kiket/workflows/monitored-process.yaml');
  }

  return { root, created, skipped };
}

export function validateConfigText(yaml: string) {
  try {
    const definition = parseWorkflow(yaml);
    const errors = validateGraph(definition);
    return { valid: errors.length === 0, errors, definition: definition as unknown as Record<string, unknown> };
  } catch (error) {
    return { valid: false, errors: [error instanceof Error ? error.message : 'Invalid process config'] };
  }
}

export async function migrateConfig(root: string, targetPath: string | undefined, write: boolean) {
  const files = targetPath
    ? [path.resolve(root, targetPath)]
    : await collectYamlFiles(path.join(root, '.kiket/workflows'));
  const results: MigrationResult[] = [];

  for (const file of files) {
    const original = await readFile(file, 'utf8');
    const migration = migrateWorkflowConfigYaml(original);
    if (migration.changed && write) await writeFile(file, migration.yaml, 'utf8');
    results.push({
      path: path.relative(root, file),
      changed: migration.changed,
      written: migration.changed && write,
      changes: migration.changes.map((change) => change.message),
      warnings: migration.warnings,
    });
  }

  return { write, results };
}

async function collectYamlFiles(root: string): Promise<string[]> {
  if (!(await pathExists(root))) return [];
  const entries = await readdir(root);
  const files: string[] = [];
  for (const entry of entries) {
    const absolute = path.join(root, entry);
    const info = await stat(absolute);
    if (info.isDirectory()) files.push(...(await collectYamlFiles(absolute)));
    if (info.isFile() && /\.(ya?ml)$/i.test(entry)) files.push(absolute);
  }
  return files;
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}
