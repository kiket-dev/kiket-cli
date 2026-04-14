import { isCancel, password, select, text } from '@clack/prompts';
import { KiketClient } from '../lib/kiket-client/index.js';
import { clearAuth, loadConfig, saveConfig } from '../lib/config.js';
import { printKeyValue } from '../lib/output.js';

export async function authLogin(options: { baseUrl?: string; organizationId?: string }) {
  const current = await loadConfig();
  const baseUrl =
    options.baseUrl ??
    String(
      await text({
        message: 'API base URL',
        defaultValue: current.baseUrl,
      }),
    );

  const email = await text({ message: 'Email' });
  if (isCancel(email) || typeof email !== 'string' || email.trim() === '') return;
  const pass = await password({ message: 'Password' });
  if (isCancel(pass) || typeof pass !== 'string' || pass.trim() === '') return;

  const client = new KiketClient({ baseUrl, userAgent: '@kiket/cli' });
  const result = await client.login(email, pass);
  let finalResult = result;
  let organizationId = options.organizationId ?? current.organizationId;

  if ('selectOrganization' in result) {
    const selected = await select({
      message: 'Select an organization',
      options: result.organizations.map((org) => ({
        value: org.id,
        label: `${org.name} (${org.slug})`,
        hint: org.role,
      })),
    });
    if (isCancel(selected) || typeof selected !== 'string' || selected.trim() === '') return;
    organizationId = selected;
    finalResult = await client.selectOrganization(result.userId, organizationId);
  }

  if ('selectOrganization' in finalResult) {
    throw new Error('Organization selection did not complete successfully.');
  }

  await saveConfig({
    baseUrl,
    auth: { kind: 'jwt', token: finalResult.accessToken },
    organizationId,
    user: finalResult.user,
  });

  printKeyValue('Logged in as', finalResult.user.email);
  printKeyValue('Organization ID', organizationId);
}

export async function authLogout() {
  await clearAuth();
  printKeyValue('Authentication', 'cleared');
}

export async function authStatus() {
  const config = await loadConfig();
  printKeyValue('Base URL', config.baseUrl);
  printKeyValue('Organization ID', config.organizationId);
  printKeyValue('Authenticated', config.auth?.token ? 'yes' : 'no');
  printKeyValue('User', config.user?.email);
}
