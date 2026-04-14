import { printJson, printKeyValue, printSection } from '../lib/output.js';
import { getConfiguredClient } from '../lib/client.js';

function requireOrganizationId(orgId: string | undefined): string {
  if (!orgId) throw new Error('Organization ID is required. Set it in config first.');
  return orgId;
}

export async function listProjects() {
  const { client, config } = await getConfiguredClient();
  const projects = await client.listProjects(requireOrganizationId(config.organizationId));
  printJson(projects);
}

export async function showProject(projectId: string) {
  const { client, config } = await getConfiguredClient();
  const project = await client.getProject(requireOrganizationId(config.organizationId), projectId);
  printSection(project.name);
  printKeyValue('ID', project.id);
  printKeyValue('Key', project.key);
  printKeyValue('Description', project.description);
}
