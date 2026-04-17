import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { z } from 'zod';

const cliConfigSchema = z.object({
  baseUrl: z.string().url().default('http://localhost:3000'),
  auth: z
    .object({
      kind: z.literal('jwt'),
      token: z.string(),
    })
    .optional(),
  organizationId: z.string().uuid().optional(),
  user: z
    .object({
      id: z.string().uuid(),
      email: z.string().email(),
      name: z.string(),
    })
    .optional(),
});

export type CliConfig = z.infer<typeof cliConfigSchema>;

export const defaultConfig: CliConfig = {
  baseUrl: process.env.KIKET_API_URL ?? 'http://localhost:3000',
};

export function getConfigPath(): string {
  return join(homedir(), '.config', 'kiket', 'cli.json');
}

export async function loadConfig(path = getConfigPath()): Promise<CliConfig> {
  try {
    const raw = await readFile(path, 'utf8');
    return cliConfigSchema.parse(JSON.parse(raw));
  } catch {
    return defaultConfig;
  }
}

export async function saveConfig(config: CliConfig, path = getConfigPath()): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(cliConfigSchema.parse(config), null, 2)}\n`, 'utf8');
}

export async function clearAuth(path = getConfigPath()): Promise<void> {
  const config = await loadConfig(path);
  await saveConfig(
    {
      ...config,
      auth: undefined,
      user: undefined,
    },
    path,
  );
}
