import { describe, expect, it } from 'vitest';
import {
  KIKET_EXTENSION_MANIFEST_FILENAME,
  validateExtensionManifestYaml,
} from '../src/extension-scaffold.js';

describe('extension-scaffold', () => {
  it('uses a Kiket-branded manifest filename', () => {
    expect(KIKET_EXTENSION_MANIFEST_FILENAME).toBe('kiket-extension.yaml');
  });

  it('validates a minimal kiket.dev/v1 Extension manifest', () => {
    const yaml = `apiVersion: kiket.dev/v1
kind: Extension
metadata:
  key: kiket-ext-webhook
  name: Webhook Adapter
  version: 0.1.0
spec:
  sourceSystem: webhook
  ingestionScopes:
    - raw-events:write
    - evidence:write
`;
    const result = validateExtensionManifestYaml(yaml);
    expect(result.valid).toBe(true);
    expect(result.errors).toEqual([]);
  });

  it('rejects manifests missing apiVersion', () => {
    const result = validateExtensionManifestYaml('kind: Extension');
    expect(result.valid).toBe(false);
    expect(result.errors).toContain('apiVersion must be kiket.dev/v1');
  });
});
