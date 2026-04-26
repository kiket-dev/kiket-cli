import { KiketClient } from '@kiket/api-client';

export type CliEnv = Record<string, string | undefined>;

export interface ClientOptions {
  apiUrl?: string;
  token?: string;
  apiKey?: string;
  organizationId?: string;
  env?: CliEnv;
  fetchImpl?: typeof fetch;
}

export function createClient(options: ClientOptions = {}): KiketClient {
  const env = options.env ?? process.env;
  const baseUrl = options.apiUrl ?? env.KIKET_API_URL ?? 'http://localhost:3000';
  const token = options.token ?? env.KIKET_API_TOKEN;
  const apiKey = options.apiKey ?? env.KIKET_API_KEY;
  const organizationId = options.organizationId ?? env.KIKET_ORGANIZATION_ID;
  const auth = token ? { kind: 'jwt' as const, token } : apiKey ? { kind: 'apiKey' as const, apiKey } : undefined;

  return new KiketClient({
    baseUrl,
    auth,
    organizationId,
    fetchImpl: options.fetchImpl,
    userAgent: '@kiket/cli',
  });
}

export function requireApiAuth(options: ClientOptions = {}) {
  const env = options.env ?? process.env;
  if (!(options.token ?? env.KIKET_API_TOKEN) && !(options.apiKey ?? env.KIKET_API_KEY)) {
    throw new Error('Set KIKET_API_TOKEN or KIKET_API_KEY for API-backed CLI commands.');
  }
  if (!(options.organizationId ?? env.KIKET_ORGANIZATION_ID)) {
    throw new Error('Set KIKET_ORGANIZATION_ID so CLI commands run in an explicit tenant context.');
  }
}
