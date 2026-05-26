import { describe, expect, it } from 'vitest';
import { buildExtensionPublishBody, parseExtensionPublishVisibility } from '../src/extension-publish.js';

const SAMPLE_MANIFEST = `apiVersion: kiket.dev/v1
kind: Extension
metadata:
  key: acme-audit
  name: Acme Audit
  version: 1.0.0
spec:
  sourceSystem: webhook
  sourceEventTypes: [evidence.observed]
`;

describe('extension publish CLI', () => {
  it('builds publish body with git URL', () => {
    const body = buildExtensionPublishBody({
      visibility: 'public',
      manifestYaml: SAMPLE_MANIFEST,
      defaultGitUrl: 'https://github.com/acme/audit',
    });
    expect(body.visibility).toBe('public');
    expect(body.manifestYaml).toContain('kiket.dev/v1');
  });

  it('requires publisher contact without git URL', () => {
    expect(() =>
      buildExtensionPublishBody({
        visibility: 'org',
        manifestYaml: SAMPLE_MANIFEST,
      }),
    ).toThrow(/publisher-contact/);
  });

  it('parses visibility', () => {
    expect(parseExtensionPublishVisibility('org')).toBe('org');
  });
});
