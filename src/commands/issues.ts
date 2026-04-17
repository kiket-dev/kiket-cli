import { getConfiguredClient } from '../lib/client.js';
import { printJson, printKeyValue, printSection } from '../lib/output.js';

export async function listIssues(options: { projectId?: string; state?: string; assigneeId?: string }) {
  const { client } = await getConfiguredClient();
  const issues = await client.listIssues(options);
  printJson(issues);
}

export async function showIssue(issueId: string) {
  const { client } = await getConfiguredClient();
  const issue = await client.getIssue(issueId);
  printSection(issue.title);
  printKeyValue('ID', issue.id);
  printKeyValue('State', issue.currentState);
  printKeyValue('Type', issue.issueType);
  printKeyValue('Priority', issue.priority);
  printKeyValue('Assignee', issue.assigneeName);
}

export async function createIssue(options: {
  workflowKey?: string;
  projectId?: string;
  title?: string;
  description?: string;
  issueType?: string;
  priority?: 'low' | 'medium' | 'high' | 'critical';
}) {
  if (!options.workflowKey) throw new Error('--workflow-key is required');
  if (!options.title) throw new Error('--title is required');
  const { client } = await getConfiguredClient();
  const issue = await client.createIssue({
    workflowKey: options.workflowKey,
    projectId: options.projectId,
    title: options.title,
    description: options.description,
    issueType: options.issueType,
    priority: options.priority,
  });
  printJson(issue);
}

export async function transitionIssue(issueId: string, targetState: string) {
  const { client } = await getConfiguredClient();
  const result = await client.transitionIssue(issueId, targetState);
  printJson(result);
}

export async function listIssueTypes() {
  const { client } = await getConfiguredClient();
  const issueTypes = await client.listIssueTypes();
  printJson(issueTypes);
}
