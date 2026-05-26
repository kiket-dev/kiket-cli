import { describe, expect, it } from 'vitest';
import { buildExtensionInstallBody, parseExtensionInstallTransport } from '../src/extension-install.js';

describe('extension install CLI', () => {
  it('builds pull runtime configuration', () => {
    const body = buildExtensionInstallBody({
      extensionKey: 'kiket-ext-acme',
      displayName: 'Acme',
      version: '1.0.0',
      transport: 'pull',
      pollIntervalSeconds: 15,
      claimBatchSize: 5,
    });

    expect(body.configuration.runtime).toEqual({
      mode: 'pull',
      status: 'ready',
      pollIntervalSeconds: 15,
      claimBatchSize: 5,
    });
  });

  it('requires endpoint URL for push transport', () => {
    expect(() =>
      buildExtensionInstallBody({
        extensionKey: 'kiket-ext-acme',
        displayName: 'Acme',
        version: '1.0.0',
        transport: 'push',
      }),
    ).toThrow(/endpoint-url/);
  });

  it('parses supported transports', () => {
    expect(parseExtensionInstallTransport('push')).toBe('push');
    expect(() => parseExtensionInstallTransport('smtp')).toThrow(/catalog_hosted/);
  });
});
