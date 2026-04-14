import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { scaffoldExtension, supportedExtensionLanguages } from '../src/lib/extension-scaffold.js';

describe('scaffoldExtension', () => {
  for (const language of supportedExtensionLanguages) {
    it(`creates a usable ${language} scaffold`, async () => {
      const directory = await mkdtemp(join(tmpdir(), `kiket-${language}-`));
      await scaffoldExtension({
        name: 'Example Extension',
        language,
        directory,
      });

      const readme = await readFile(join(directory, 'README.md'), 'utf8');
      expect(readme).toContain('Example Extension');

      const workflow = await readFile(join(directory, '.github', 'workflows', 'test.yml'), 'utf8');
      expect(workflow).toContain('name: test');
    });
  }
});
