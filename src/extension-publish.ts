import { readExtensionManifest, validateExtensionManifestYaml } from './extension-scaffold.js';

export interface ExtensionPublishCliInput {
  visibility: 'public' | 'org';
  manifestYaml: string;
  defaultGitUrl?: string;
  defaultRef?: string;
  publisherContact?: string;
  docsUrl?: string;
}

export function parseExtensionPublishVisibility(value: unknown): 'public' | 'org' {
  if (value === 'public' || value === 'org') return value;
  throw new Error('Only --visibility public or org is supported.');
}

export function buildExtensionPublishBody(input: ExtensionPublishCliInput): {
  visibility: 'public' | 'org';
  manifestYaml: string;
  defaultGitUrl?: string;
  defaultRef?: string;
  publisherContact?: string;
  docsUrl?: string;
} {
  const validated = validateExtensionManifestYaml(input.manifestYaml);
  if (!validated.valid) {
    throw new Error(validated.errors.join('; '));
  }
  if (!input.defaultGitUrl && !input.publisherContact) {
    throw new Error('Closed-source listings require --publisher-contact when --git-url is omitted');
  }
  return {
    visibility: input.visibility,
    manifestYaml: input.manifestYaml,
    defaultGitUrl: input.defaultGitUrl,
    defaultRef: input.defaultRef,
    publisherContact: input.publisherContact,
    docsUrl: input.docsUrl,
  };
}

export async function readManifestForPublish(cwd: string, file?: string): Promise<string> {
  return readExtensionManifest(cwd, file);
}
