import { scaffoldExtension, supportedExtensionLanguages } from '../lib/extension-scaffold.js';
import type { SupportedExtensionLanguage } from '../lib/extension-scaffold.js';
import { printKeyValue } from '../lib/output.js';

export async function scaffold(name: string, language: string, directory?: string) {
  if (!supportedExtensionLanguages.includes(language as SupportedExtensionLanguage)) {
    throw new Error(`Unsupported language: ${language}`);
  }

  const targetDirectory = directory ?? name;
  await scaffoldExtension({
    name,
    language: language as SupportedExtensionLanguage,
    directory: targetDirectory,
  });

  printKeyValue('Extension scaffolded', targetDirectory);
}
