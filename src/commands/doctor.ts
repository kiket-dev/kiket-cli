import { getConfiguredClient } from '../lib/client.js';
import { printJson } from '../lib/output.js';

export async function doctor() {
  const { client } = await getConfiguredClient();
  const [health, user] = await Promise.all([client.getHealth(), client.getCurrentUser()]);
  printJson({ health, user });
}
