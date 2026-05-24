import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parse as parseYaml, stringify as stringifyYaml } from 'yaml';

/** Canonical platform extension manifest filename at the adapter repo root. */
export const KIKET_EXTENSION_MANIFEST_FILENAME = 'kiket-extension.yaml';

export type ExtensionTemplate = 'webhook' | 'github' | 'slack';

export interface ExtensionInitResult {
  root: string;
  created: string[];
  skipped: string[];
}

export interface ExtensionValidateResult {
  valid: boolean;
  errors: string[];
  manifest?: Record<string, unknown>;
}

const TEMPLATE_MANIFESTS: Record<ExtensionTemplate, Record<string, unknown>> = {
  webhook: {
    apiVersion: 'kiket.dev/v1',
    kind: 'Extension',
    metadata: {
      key: 'my-webhook-adapter',
      name: 'Generic Webhook Adapter',
      version: '0.1.0',
      description: 'Map inbound JSON payloads into Kiket evidence using field mappings.',
    },
    spec: {
      sourceSystem: 'webhook',
      ingestionScopes: ['raw-events:write', 'evidence:write'],
      sourceEventTypes: ['inbound', 'approval'],
      evidenceTypes: ['approval', 'webhook'],
      retentionHints: { rawDays: 30, evidenceDays: 365 },
    },
  },
  github: {
    apiVersion: 'kiket.dev/v1',
    kind: 'Extension',
    metadata: {
      key: 'github',
      name: 'GitHub Evidence Adapter',
      version: '0.1.0',
      description: 'Normalize GitHub webhook events into Kiket evidence.',
    },
    spec: {
      sourceSystem: 'github',
      ingestionScopes: ['raw-events:write', 'evidence:write'],
      sourceEventTypes: ['pull_request', 'issues', 'issue_comment', 'check_run'],
      evidenceTypes: ['pull_request', 'github_issue', 'issue_comment', 'check_run'],
      retentionHints: { rawDays: 30, evidenceDays: 365 },
    },
  },
  slack: {
    apiVersion: 'kiket.dev/v1',
    kind: 'Extension',
    metadata: {
      key: 'slack',
      name: 'Slack Evidence Adapter',
      version: '0.1.0',
      description: 'Normalize Slack approval messages into Kiket evidence.',
    },
    spec: {
      sourceSystem: 'slack',
      ingestionScopes: ['raw-events:write', 'evidence:write'],
      sourceEventTypes: ['event_callback', 'message'],
      evidenceTypes: ['slack_message', 'slack_approval'],
      retentionHints: { rawDays: 30, evidenceDays: 365 },
    },
  },
};

const STARTER_EXTENSION_MANIFEST = TEMPLATE_MANIFESTS.webhook;

export async function initExtension(
  root: string,
  force = false,
  template: ExtensionTemplate = 'webhook',
): Promise<ExtensionInitResult> {
  const created: string[] = [];
  const skipped: string[] = [];
  const srcDir = path.join(root, 'src');
  await mkdir(srcDir, { recursive: true });
  created.push('src');

  const manifestPath = path.join(root, KIKET_EXTENSION_MANIFEST_FILENAME);
  if ((await pathExists(manifestPath)) && !force) {
    skipped.push(KIKET_EXTENSION_MANIFEST_FILENAME);
  } else {
    await writeFile(manifestPath, `${stringifyYaml(TEMPLATE_MANIFESTS[template])}`, 'utf8');
    created.push(KIKET_EXTENSION_MANIFEST_FILENAME);
  }

  const adapterPath = path.join(srcDir, 'adapter.ts');
  if ((await pathExists(adapterPath)) && !force) {
    skipped.push('src/adapter.ts');
  } else {
    await writeFile(
      adapterPath,
      `/**
 * Evidence adapter entrypoint — POST normalized payloads via Kiket platform ingestion APIs.
 * Use \`kiket extension test\` with a fixture JSON to verify API-key scoped ingest.
 */
export async function normalizeInbound(payload: Record<string, unknown>) {
  return {
    sourceSystem: 'webhook',
    sourceEventType: 'inbound',
    idempotencyKey: \`webhook:\${String(payload.id ?? Date.now())}\`,
    payload,
  };
}
`,
      'utf8',
    );
    created.push('src/adapter.ts');
  }

  return { root, created, skipped };
}

export function validateExtensionManifestYaml(yamlText: string): ExtensionValidateResult {
  try {
    const parsed = parseYaml(yamlText) as Record<string, unknown>;
    const errors: string[] = [];

    if (parsed.apiVersion !== 'kiket.dev/v1') errors.push('apiVersion must be kiket.dev/v1');
    if (parsed.kind !== 'Extension') errors.push('kind must be Extension');

    const metadata = parsed.metadata;
    if (!metadata || typeof metadata !== 'object') {
      errors.push('metadata is required');
    } else {
      const meta = metadata as Record<string, unknown>;
      if (typeof meta.key !== 'string' || meta.key.length === 0) errors.push('metadata.key is required');
      if (typeof meta.name !== 'string' || meta.name.length === 0) errors.push('metadata.name is required');
      if (typeof meta.version !== 'string' || meta.version.length === 0) errors.push('metadata.version is required');
    }

    const spec = parsed.spec;
    if (!spec || typeof spec !== 'object') {
      errors.push('spec is required');
    } else {
      const specObj = spec as Record<string, unknown>;
      if (typeof specObj.sourceSystem !== 'string' || specObj.sourceSystem.length === 0) {
        errors.push('spec.sourceSystem is required');
      }
      const scopes = specObj.ingestionScopes;
      if (scopes !== undefined) {
        if (!Array.isArray(scopes) || scopes.length === 0) {
          errors.push('spec.ingestionScopes must be a non-empty array when present');
        } else if (!scopes.every((scope) => scope === 'raw-events:write' || scope === 'evidence:write')) {
          errors.push('spec.ingestionScopes may only include raw-events:write and evidence:write');
        }
      }
    }

    return errors.length === 0
      ? { valid: true, errors: [], manifest: parsed }
      : { valid: false, errors, manifest: parsed };
  } catch (error) {
    return {
      valid: false,
      errors: [error instanceof Error ? error.message : `Invalid ${KIKET_EXTENSION_MANIFEST_FILENAME}`],
    };
  }
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

export async function readExtensionManifest(root: string, file?: string): Promise<string> {
  const manifestPath = file ? path.resolve(root, file) : path.join(root, KIKET_EXTENSION_MANIFEST_FILENAME);
  return readFile(manifestPath, 'utf8');
}
