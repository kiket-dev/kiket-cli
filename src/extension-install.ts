export type ExtensionInstallTransport = 'catalog_hosted' | 'push' | 'pull';

export interface ExtensionInstallCliInput {
  extensionKey: string;
  displayName: string;
  version: string;
  workspaceId?: string;
  transport: ExtensionInstallTransport;
  endpointUrl?: string;
  pollIntervalSeconds?: number;
  claimBatchSize?: number;
}

export function buildExtensionInstallBody(input: ExtensionInstallCliInput): {
  extensionKey: string;
  displayName: string;
  version: string;
  workspaceId?: string;
  configuration: Record<string, unknown>;
} {
  const runtime: Record<string, unknown> = {
    mode: input.transport,
    status: 'ready',
  };

  if (input.transport === 'push') {
    if (!input.endpointUrl) {
      throw new Error('push transport requires --endpoint-url');
    }
    runtime.endpointUrl = input.endpointUrl;
  }

  if (input.transport === 'pull') {
    if (input.pollIntervalSeconds !== undefined) runtime.pollIntervalSeconds = input.pollIntervalSeconds;
    if (input.claimBatchSize !== undefined) runtime.claimBatchSize = input.claimBatchSize;
  }

  return {
    extensionKey: input.extensionKey,
    displayName: input.displayName,
    version: input.version,
    ...(input.workspaceId ? { workspaceId: input.workspaceId } : {}),
    configuration: { runtime },
  };
}

export function parseExtensionInstallTransport(value: unknown): ExtensionInstallTransport {
  if (value === 'catalog_hosted' || value === 'push' || value === 'pull') return value;
  throw new Error('Only --transport catalog_hosted, push, or pull is supported.');
}
