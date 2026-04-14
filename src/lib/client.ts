import { KiketClient } from './kiket-client/index.js';
import { fail } from './output.js';
import { loadConfig } from './config.js';

export async function getConfiguredClient() {
  const config = await loadConfig();
  if (!config.auth?.token) {
    fail('Not authenticated. Run `kiket auth login` first.');
  }

  return {
    config,
    client: new KiketClient({
      baseUrl: config.baseUrl,
      auth: { kind: 'jwt', token: config.auth.token },
      organizationId: config.organizationId,
      userAgent: '@kiket/cli',
    }),
  };
}
