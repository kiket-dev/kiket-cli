import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { runCli } from '../src/commands.js';

function apiEnv() {
  return {
    KIKET_API_TOKEN: 'token',
    KIKET_ORGANIZATION_ID: '00000000-0000-4000-8000-000000000001',
  };
}

describe('kiket CLI', () => {
  it('keeps help text on workspace/process/case vocabulary', async () => {
    const result = await runCli(['--help']);
    const body = JSON.parse(result.stdout) as { help: string };

    expect(result.exitCode).toBe(0);
    expect(body.help).toContain('--workspace-id');
    expect(body.help).toContain('--process-id');
    expect(body.help).toContain('--case-id');
    expect(body.help.toLowerCase()).not.toMatch(/\b(project|projects|issue|issues|task|tasks)\b/);
  });

  it('initializes file-backed compliance config non-interactively', async () => {
    const cwd = await mkdtemp(path.join(os.tmpdir(), 'kiket-cli-'));
    const result = await runCli(['init'], { cwd });

    expect(result).toMatchObject({ exitCode: 0 });
    const body = JSON.parse(result.stdout) as { created: string[] };
    expect(body.created).toContain('.kiket/workflows/monitored-process.yaml');
    await expect(readFile(path.join(cwd, '.kiket/workflows/monitored-process.yaml'), 'utf8')).resolves.toContain(
      'model_version: "2.0"',
    );
  });

  it('migrates legacy workflow YAML locally without writing by default', async () => {
    const cwd = await mkdtemp(path.join(os.tmpdir(), 'kiket-cli-'));
    const workflowPath = path.join(cwd, 'workflow.yaml');
    await writeFile(
      workflowPath,
      `model_version: "1.0"
workflow:
  id: contract
  name: Contract Review
  version: "1.0"
states:
  draft:
    type: initial
    documents:
      - id: contract
        label: Draft Contract
  legal_review:
    type: active
    approval:
      required: 1
      approvers:
        - role: legal
  done:
    type: final
transitions:
  - from: draft
    to: legal_review
  - from: legal_review
    to: done
`,
      'utf8',
    );

    const result = await runCli(['migrate-config', '--file', 'workflow.yaml'], { cwd });

    expect(result.stderr).toBeUndefined();
    expect(result).toMatchObject({ exitCode: 0 });
    const body = JSON.parse(result.stdout) as {
      results: Array<{ changed: boolean; written: boolean; changes: string[] }>;
    };
    expect(body.results[0]?.changed).toBe(true);
    expect(body.results[0]?.written).toBe(false);
    expect(body.results[0]?.changes.join('\n')).toContain('Added process metadata');
    await expect(readFile(workflowPath, 'utf8')).resolves.toContain('model_version: "1.0"');
  });

  it('writes migrated workflow YAML only when --write is provided', async () => {
    const cwd = await mkdtemp(path.join(os.tmpdir(), 'kiket-cli-'));
    const workflowPath = path.join(cwd, 'workflow.yaml');
    await writeFile(
      workflowPath,
      `workflow:
  id: privacy-request
  name: Privacy Request
  version: "1.0"
states:
  received:
    type: initial
    sla:
      warning: 24h
      breach: 72h
  completed:
    type: final
transitions:
  - from: received
    to: completed
`,
      'utf8',
    );

    const result = await runCli(['migrate-config', '--file', 'workflow.yaml', '--write'], { cwd });

    expect(result.stderr).toBeUndefined();
    expect(result.exitCode).toBe(0);
    const body = JSON.parse(result.stdout) as { results: Array<{ written: boolean }> };
    expect(body.results[0]?.written).toBe(true);
    const migrated = await readFile(workflowPath, 'utf8');
    expect(migrated).toContain('model_version: "2.0"');
    expect(migrated).toContain('process:');
    expect(migrated).toContain('received-sla-monitoring');
  });

  it('uses the authorized API client for config validation by default', async () => {
    const cwd = await mkdtemp(path.join(os.tmpdir(), 'kiket-cli-'));
    await writeFile(path.join(cwd, 'workflow.yaml'), 'key: change\nstates: []\ntransitions: []\n', 'utf8');
    const client = {
      validateConfig: vi.fn(async () => ({ valid: true, errors: [] })),
    };

    const result = await runCli(['validate', '--file', 'workflow.yaml'], {
      cwd,
      env: apiEnv(),
      client: client as never,
    });

    expect(result.exitCode).toBe(0);
    expect(client.validateConfig).toHaveBeenCalledWith('key: change\nstates: []\ntransitions: []\n');
  });

  it('routes scan, report, evidence, anchor, and extension commands through the API client', async () => {
    const cwd = await mkdtemp(path.join(os.tmpdir(), 'kiket-cli-'));
    await writeFile(
      path.join(cwd, 'evidence.json'),
      JSON.stringify({ evidenceType: 'approval', title: 'Approved', sourceSystem: 'github', dedupeKey: 'approval:1' }),
      'utf8',
    );
    await writeFile(
      path.join(cwd, 'event.json'),
      JSON.stringify({
        sourceSystem: 'github',
        sourceEventType: 'pull_request',
        idempotencyKey: 'github:1',
        payload: {},
      }),
      'utf8',
    );
    const client = {
      triggerScannerRun: vi.fn(async () => ({ run: { id: 'scan-1' }, findings: [] })),
      importEvidence: vi.fn(async () => ({ id: 'evidence-1' })),
      generateReport: vi.fn(async () => ({ id: 'report-1' })),
      verifyReport: vi.fn(async () => ({ valid: true })),
      createAnchorProof: vi.fn(async () => ({ id: 'anchor-1', status: 'local_only' })),
      verifyAnchor: vi.fn(async () => ({ valid: true })),
      ingestRawEvent: vi.fn(async () => ({ rawEvent: { id: 'raw-1' }, duplicate: false })),
    };

    await runCli(['scan', '--idempotency-key', 'cli:test'], { env: apiEnv(), client: client as never });
    await runCli(['evidence', 'import', '--file', 'evidence.json'], { cwd, env: apiEnv(), client: client as never });
    await runCli(['report', 'generate', '--report-key', 'audit', '--title', 'Audit'], {
      env: apiEnv(),
      client: client as never,
    });
    await runCli(['report', 'verify', '--id', 'report-1'], { env: apiEnv(), client: client as never });
    await runCli(
      [
        'anchor',
        'create',
        '--subject-type',
        'evidence',
        '--subject-id',
        '00000000-0000-4000-8000-000000000002',
        '--subject-hash',
        'abc123',
        '--chain',
        'polygon',
        '--network',
        'amoy',
        '--request-submission',
      ],
      { env: apiEnv(), client: client as never },
    );
    await runCli(['anchor', 'verify', '--id', 'anchor-1'], { env: apiEnv(), client: client as never });
    await runCli(['extension', 'test', '--file', 'event.json'], { cwd, env: apiEnv(), client: client as never });

    expect(client.triggerScannerRun).toHaveBeenCalled();
    expect(client.importEvidence).toHaveBeenCalled();
    expect(client.generateReport).toHaveBeenCalledWith({ reportKey: 'audit', title: 'Audit' });
    expect(client.verifyReport).toHaveBeenCalledWith('report-1');
    expect(client.createAnchorProof).toHaveBeenCalledWith({
      subjectType: 'evidence',
      subjectId: '00000000-0000-4000-8000-000000000002',
      subjectHash: 'abc123',
      chain: 'polygon',
      network: 'amoy',
      requestSubmission: true,
    });
    expect(client.verifyAnchor).toHaveBeenCalledWith('anchor-1');
    expect(client.ingestRawEvent).toHaveBeenCalled();
  });

  it('requires explicit tenant auth for API-backed commands', async () => {
    const result = await runCli(['scan'], { env: {} });
    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain('KIKET_API_TOKEN');
  });
});
