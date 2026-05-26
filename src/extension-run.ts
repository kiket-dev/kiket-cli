import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export type ExtensionTransport = 'push' | 'pull';

export interface ExtensionRunInput {
  transport: ExtensionTransport;
  port: number;
  env: NodeJS.ProcessEnv;
}

export function resolveExtensionRunnerEntry(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, '../../apps/extension-runner/src/index.ts');
}

export function buildExtensionRunEnv(input: ExtensionRunInput): NodeJS.ProcessEnv {
  return {
    ...input.env,
    KIKET_EXTENSION_TRANSPORT: input.transport,
    KIKET_EXTENSION_RUNNER_PORT: String(input.port),
  };
}

export async function runExtensionRunner(input: ExtensionRunInput): Promise<{ pid: number; command: string }> {
  const entry = resolveExtensionRunnerEntry();
  const env = buildExtensionRunEnv(input);
  const child = spawn('pnpm', ['exec', 'tsx', entry], {
    cwd: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'),
    env,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });

  return new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('spawn', () => {
      if (child.pid === undefined) {
        reject(new Error('Failed to start extension runner'));
        return;
      }
      resolve({ pid: child.pid, command: `tsx ${entry}` });
    });
  });
}
