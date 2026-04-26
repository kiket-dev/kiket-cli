import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import type { KiketClient } from '@kiket/api-client';
import { type CliEnv, createClient, requireApiAuth } from './client.js';
import { initConfig, migrateConfig, validateConfigText } from './local-config.js';

export interface CliDeps {
  cwd?: string;
  env?: CliEnv;
  client?: KiketClient;
  readStdin?: () => Promise<string>;
  fetchImpl?: typeof fetch;
}

export interface CliResult {
  exitCode: number;
  stdout: string;
  stderr?: string;
}

type OutputFormat = 'json' | 'text';

const HELP = `Kiket CLI

Usage:
  kiket init [--root <path>] [--force]
  kiket validate --file <path> [--local]
  kiket migrate-config [--file <path>] [--write]
  kiket simulate --original <path> --modified <path> [--instances <json>]
  kiket scan [--workspace-id <id>] [--process-id <id>] [--case-id <id>] [--trigger manual] [--idempotency-key <key>]
  kiket findings list [--status <status>] [--workspace-id <id>] [--process-id <id>] [--case-id <id>]
  kiket evidence import --file <json>
  kiket report generate --report-key <key> --title <title> [--workspace-id <id>] [--process-id <id>] [--case-id <id>]
  kiket report verify --id <report-id>
  kiket anchor create --subject-type <type> --subject-id <id> --subject-hash <hash> [--workspace-id <id>] [--chain <chain>] [--network <network>] [--request-submission]
  kiket anchor verify --id <anchor-id>
  kiket extension test --file <json>

Global options:
  --api-url <url>              Defaults to KIKET_API_URL or http://localhost:3000
  --token <jwt>                Defaults to KIKET_API_TOKEN
  --api-key <key>              Defaults to KIKET_API_KEY
  --organization-id <id>       Defaults to KIKET_ORGANIZATION_ID
  --format json|text           Defaults to json
`;

export async function runCli(argv: string[], deps: CliDeps = {}): Promise<CliResult> {
  try {
    const { globalArgs, positionals } = splitGlobalArgs(argv);
    const parsed = parseArgs({
      args: globalArgs,
      allowPositionals: false,
      options: {
        'api-url': { type: 'string' },
        token: { type: 'string' },
        'api-key': { type: 'string' },
        'organization-id': { type: 'string' },
        format: { type: 'string', default: 'json' },
        help: { type: 'boolean', short: 'h' },
      },
    });
    const format = parseFormat(parsed.values.format);
    if (parsed.values.help || positionals.length === 0) {
      return output({ help: HELP }, format, HELP);
    }

    const clientOptions = {
      apiUrl: parsed.values['api-url'],
      token: parsed.values.token,
      apiKey: parsed.values['api-key'],
      organizationId: parsed.values['organization-id'],
      env: deps.env,
      fetchImpl: deps.fetchImpl,
    };
    const client = deps.client ?? createClient(clientOptions);
    const cwd = deps.cwd ?? process.cwd();
    const [command] = positionals;
    const commandArgs = positionals.slice(1);

    switch (command) {
      case 'init':
        return output(await initConfig(resolveRoot(cwd, commandArgs), readForce(commandArgs)), format);
      case 'validate':
        return output(await validateCommand(commandArgs, cwd, client, clientOptions), format);
      case 'migrate-config':
        return output(await migrateCommand(commandArgs, cwd), format);
      case 'simulate':
        requireApiAuth(clientOptions);
        return output(await simulateCommand(commandArgs, cwd, client), format);
      case 'scan':
        requireApiAuth(clientOptions);
        return output(await scanCommand(commandArgs, client), format);
      case 'findings':
        if (commandArgs[0] !== 'list') throw new Error('Use `kiket findings list`.');
        requireApiAuth(clientOptions);
        return output(await findingsListCommand(commandArgs.slice(1), client), format);
      case 'evidence':
        if (commandArgs[0] !== 'import') throw new Error('Use `kiket evidence import`.');
        requireApiAuth(clientOptions);
        return output(await evidenceImportCommand(commandArgs.slice(1), cwd, client, deps.readStdin), format);
      case 'report':
        requireApiAuth(clientOptions);
        return output(await reportCommand(commandArgs[0], commandArgs.slice(1), client), format);
      case 'anchor':
        requireApiAuth(clientOptions);
        return output(await anchorCommand(commandArgs[0], commandArgs.slice(1), client), format);
      case 'extension':
        if (commandArgs[0] !== 'test') throw new Error('Use `kiket extension test`.');
        requireApiAuth(clientOptions);
        return output(await extensionTestCommand(commandArgs.slice(1), cwd, client, deps.readStdin), format);
      default:
        throw new Error(`Unknown command "${command}".`);
    }
  } catch (error) {
    return { exitCode: 1, stdout: '', stderr: error instanceof Error ? error.message : 'Command failed' };
  }
}

function splitGlobalArgs(argv: string[]) {
  const commandIndex = argv.findIndex((arg) => !arg.startsWith('-'));
  if (commandIndex === -1) return { globalArgs: argv, positionals: [] as string[] };
  return { globalArgs: argv.slice(0, commandIndex), positionals: argv.slice(commandIndex) };
}

async function validateCommand(
  args: string[],
  cwd: string,
  client: KiketClient,
  clientOptions: Parameters<typeof requireApiAuth>[0],
) {
  const options = readOptions(args);
  const yaml = await readFile(resolvePath(cwd, required(options, 'file')), 'utf8');
  if (options.local === true) return validateConfigText(yaml);
  requireApiAuth(clientOptions);
  return client.validateConfig(yaml);
}

async function migrateCommand(args: string[], cwd: string) {
  const options = readOptions(args);
  return migrateConfig(cwd, typeof options.file === 'string' ? options.file : undefined, options.write === true);
}

async function simulateCommand(args: string[], cwd: string, client: KiketClient) {
  const options = readOptions(args);
  const instances = options.instances ? JSON.parse(await readInput(cwd, String(options.instances))) : [];
  return client.runSimulation({
    originalYaml: await readFile(resolvePath(cwd, required(options, 'original')), 'utf8'),
    modifiedYaml: await readFile(resolvePath(cwd, required(options, 'modified')), 'utf8'),
    instances,
  });
}

async function scanCommand(args: string[], client: KiketClient) {
  const options = readOptions(args);
  return client.triggerScannerRun({
    workspaceId: stringOption(options, 'workspace-id'),
    processId: stringOption(options, 'process-id'),
    caseId: stringOption(options, 'case-id'),
    trigger: (stringOption(options, 'trigger') ?? 'manual') as
      | 'event'
      | 'scheduled'
      | 'backfill'
      | 'manual'
      | 'simulation',
    idempotencyKey: stringOption(options, 'idempotency-key') ?? `cli:${crypto.randomUUID()}`,
    eventId: stringOption(options, 'event-id'),
  });
}

async function findingsListCommand(args: string[], client: KiketClient) {
  const options = readOptions(args);
  return client.listFindings({
    workspaceId: stringOption(options, 'workspace-id'),
    processId: stringOption(options, 'process-id'),
    caseId: stringOption(options, 'case-id'),
    status: stringOption(options, 'status'),
  });
}

async function evidenceImportCommand(
  args: string[],
  cwd: string,
  client: KiketClient,
  readStdin: CliDeps['readStdin'],
) {
  const options = readOptions(args);
  const input = JSON.parse(await readJsonArgument(cwd, required(options, 'file'), readStdin)) as Parameters<
    KiketClient['importEvidence']
  >[0];
  return client.importEvidence(input);
}

async function reportCommand(subcommand: string | undefined, args: string[], client: KiketClient) {
  const options = readOptions(args);
  if (subcommand === 'generate') {
    return client.generateReport({
      workspaceId: stringOption(options, 'workspace-id'),
      processId: stringOption(options, 'process-id'),
      caseId: stringOption(options, 'case-id'),
      reportKey: required(options, 'report-key'),
      title: required(options, 'title'),
      periodStart: stringOption(options, 'period-start'),
      periodEnd: stringOption(options, 'period-end'),
    });
  }
  if (subcommand === 'verify') return client.verifyReport(required(options, 'id'));
  throw new Error('Use `kiket report generate` or `kiket report verify`.');
}

async function anchorCommand(subcommand: string | undefined, args: string[], client: KiketClient) {
  const options = readOptions(args);
  if (subcommand === 'create') {
    return client.createAnchorProof({
      workspaceId: stringOption(options, 'workspace-id'),
      subjectType: required(options, 'subject-type'),
      subjectId: required(options, 'subject-id'),
      subjectHash: required(options, 'subject-hash'),
      hashAlgorithm: stringOption(options, 'hash-algorithm'),
      chain: stringOption(options, 'chain'),
      network: stringOption(options, 'network'),
      requestSubmission: options['request-submission'] === true,
    });
  }
  if (subcommand === 'verify') return client.verifyAnchor(required(options, 'id'));
  throw new Error('Use `kiket anchor create` or `kiket anchor verify`.');
}

async function extensionTestCommand(args: string[], cwd: string, client: KiketClient, readStdin: CliDeps['readStdin']) {
  const options = readOptions(args);
  const input = JSON.parse(await readJsonArgument(cwd, required(options, 'file'), readStdin)) as Parameters<
    KiketClient['ingestRawEvent']
  >[0];
  return client.ingestRawEvent(input);
}

function readOptions(args: string[]) {
  return parseArgs({
    args,
    allowPositionals: false,
    options: {
      root: { type: 'string' },
      file: { type: 'string' },
      force: { type: 'boolean' },
      local: { type: 'boolean' },
      write: { type: 'boolean' },
      original: { type: 'string' },
      modified: { type: 'string' },
      instances: { type: 'string' },
      status: { type: 'string' },
      id: { type: 'string' },
      title: { type: 'string' },
      trigger: { type: 'string' },
      'workspace-id': { type: 'string' },
      'process-id': { type: 'string' },
      'case-id': { type: 'string' },
      'event-id': { type: 'string' },
      'idempotency-key': { type: 'string' },
      'report-key': { type: 'string' },
      'period-start': { type: 'string' },
      'period-end': { type: 'string' },
      'subject-type': { type: 'string' },
      'subject-id': { type: 'string' },
      'subject-hash': { type: 'string' },
      'hash-algorithm': { type: 'string' },
      chain: { type: 'string' },
      network: { type: 'string' },
      'request-submission': { type: 'boolean' },
    },
  }).values;
}

function output(value: unknown, format: OutputFormat, text?: string): CliResult {
  if (format === 'text') return { exitCode: 0, stdout: `${text ?? String(value)}\n` };
  return { exitCode: 0, stdout: `${JSON.stringify(value, null, 2)}\n` };
}

function parseFormat(value: unknown): OutputFormat {
  if (value === 'text') return 'text';
  if (value === undefined || value === 'json') return 'json';
  throw new Error('Only --format json or --format text is supported.');
}

function resolveRoot(cwd: string, args: string[]) {
  const root = readOptions(args).root;
  return root ? resolvePath(cwd, String(root)) : cwd;
}

function readForce(args: string[]) {
  return readOptions(args).force === true;
}

function required(options: Record<string, unknown>, key: string): string {
  const value = options[key];
  if (typeof value !== 'string' || value.length === 0) throw new Error(`Missing required --${key}.`);
  return value;
}

function stringOption(options: Record<string, unknown>, key: string) {
  const value = options[key];
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function resolvePath(cwd: string, filePath: string) {
  return path.isAbsolute(filePath) ? filePath : path.join(cwd, filePath);
}

async function readInput(cwd: string, value: string) {
  if (value.trim().startsWith('{') || value.trim().startsWith('[')) return value;
  return readFile(resolvePath(cwd, value), 'utf8');
}

async function readJsonArgument(cwd: string, file: string, readStdin?: () => Promise<string>) {
  if (file === '-') {
    if (!readStdin) throw new Error('Reading from stdin is not available in this environment.');
    return readStdin();
  }
  return readFile(resolvePath(cwd, file), 'utf8');
}
