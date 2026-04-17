import { getConfiguredClient } from '../lib/client.js';
import { printJson } from '../lib/output.js';

export async function listMilestones(projectId: string) {
  const { client } = await getConfiguredClient();
  const milestones = await client.listMilestones(projectId);
  printJson(milestones);
}

export async function showMilestone(milestoneId: string) {
  const { client } = await getConfiguredClient();
  const milestone = await client.getMilestone(milestoneId);
  printJson(milestone);
}
