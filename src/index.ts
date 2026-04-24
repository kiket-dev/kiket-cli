#!/usr/bin/env node
import { cac } from 'cac';
import { authLogin, authLogout, authStatus } from './commands/auth.js';
import { listDefinitions, showDefinition } from './commands/definitions.js';
import { doctor } from './commands/doctor.js';
import { scaffold as scaffoldExtension } from './commands/extensions.js';
import { createIssue, listIssues, listIssueTypes, showIssue, transitionIssue } from './commands/issues.js';
import { listMilestones, showMilestone } from './commands/milestones.js';
import { listProjects, showProject } from './commands/projects.js';
import { listWorkflows, validateWorkflow } from './commands/workflows.js';

const cli = cac('kiket');

cli.command('auth login', 'Login with email and password').option('--base-url <url>', 'API base URL').action(authLogin);
cli.command('auth logout', 'Clear local auth').action(authLogout);
cli.command('auth status', 'Show local auth status').action(authStatus);

cli.command('doctor', 'Check API health and current auth').action(doctor);

cli.command('definitions list', 'List available template definitions').action(listDefinitions);
cli.command('definitions show <key>', 'Show one template definition').action(showDefinition);

cli.command('projects list', 'List projects').action(listProjects);
cli.command('projects show <projectId>', 'Show a project').action(showProject);

cli
  .command('issues list', 'List issues')
  .option('--project-id <projectId>', 'Project ID')
  .option('--state <state>', 'Workflow state')
  .option('--assignee-id <assigneeId>', 'Assignee ID')
  .action(listIssues);
cli.command('issues show <issueId>', 'Show an issue').action(showIssue);
cli
  .command('issues create', 'Create an issue')
  .option('--workflow-key <workflowKey>', 'Workflow key')
  .option('--project-id <projectId>', 'Project ID')
  .option('--title <title>', 'Issue title')
  .option('--description <description>', 'Issue description')
  .option('--issue-type <issueType>', 'Issue type')
  .option('--priority <priority>', 'Priority')
  .action(createIssue);
cli.command('issues transition <issueId> <targetState>', 'Transition an issue').action(transitionIssue);
cli.command('issues types', 'List issue types').action(listIssueTypes);

cli.command('milestones list <projectId>', 'List milestones for a project').action(listMilestones);
cli.command('milestones show <milestoneId>', 'Show a milestone').action(showMilestone);

cli.command('workflows list', 'List workflows').option('--project-id <projectId>', 'Project ID').action(listWorkflows);
cli.command('workflows validate <filePath>', 'Validate a workflow YAML file').action(validateWorkflow);

cli
  .command('extensions scaffold <name>', 'Scaffold a new extension project')
  .option('--language <language>', 'Language: node, python, ruby, java, dotnet, go', {
    default: 'node',
  })
  .option('--directory <directory>', 'Target directory')
  .action(scaffoldExtension);

cli.help();
cli.parse();
