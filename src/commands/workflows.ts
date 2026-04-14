import { readFile } from 'node:fs/promises';
import { printJson } from '../lib/output.js';
import { getConfiguredClient } from '../lib/client.js';

export async function listWorkflows(projectId?: string) {
  const { client } = await getConfiguredClient();
  const workflows = await client.listWorkflows(projectId);
  printJson(workflows);
}

export async function validateWorkflow(filePath: string) {
  const { client } = await getConfiguredClient();
  const yaml = await readFile(filePath, 'utf8');
  const result = await client.validateWorkflow(yaml);
  printJson(result);
}
