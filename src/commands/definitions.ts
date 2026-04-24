import { getConfiguredClient } from '../lib/client.js';
import { printJson, printKeyValue, printSection } from '../lib/output.js';

export async function listDefinitions() {
  const { client } = await getConfiguredClient();
  const definitions = await client.listDefinitions();
  printJson(definitions);
}

export async function showDefinition(key: string) {
  const { client } = await getConfiguredClient();
  const definition = await client.getDefinition(key);
  printSection(definition.name);
  printKeyValue('Key', definition.key);
  printKeyValue('Category', definition.category);
  printKeyValue('Description', definition.description);
  printKeyValue('Workflows', String(definition.workflowCount));
  printKeyValue('Boards', String(definition.boardCount));
  printKeyValue('Issue Types', String(definition.issueTypeCount));
  printKeyValue('Has Intakes', definition.hasIntakeForms ? 'yes' : 'no');
  printKeyValue('Preview States', definition.previewStates.join(', '));
}
