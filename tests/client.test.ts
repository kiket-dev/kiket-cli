import { describe, expect, it } from 'vitest';
import { KiketClient } from '../src/lib/kiket-client/client.js';

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

describe('KiketClient', () => {
  it('sends JWT auth and organization header', async () => {
    let captured: Request | undefined;
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      auth: { kind: 'jwt', token: 'jwt-token' },
      organizationId: 'org-123',
      fetchImpl: async (input, init) => {
        captured = new Request(input, init);
        return jsonResponse({
          id: '550e8400-e29b-41d4-a716-446655440000',
          email: 'test@example.com',
          name: 'Test User',
          locale: 'en',
          createdAt: '2026-01-01T00:00:00.000Z',
        });
      },
    });

    await client.getCurrentUser();

    expect(captured?.headers.get('authorization')).toBe('Bearer jwt-token');
    expect(captured?.headers.get('x-organization-id')).toBe('org-123');
  });

  it('sends API key using X-API-Key', async () => {
    let captured: Request | undefined;
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      auth: { kind: 'apiKey', apiKey: 'kiket_test' },
      fetchImpl: async (input, init) => {
        captured = new Request(input, init);
        return jsonResponse({
          data: [],
        });
      },
    });

    await client.listIssueTypes();

    expect(captured?.headers.get('x-api-key')).toBe('kiket_test');
    expect(captured?.headers.get('authorization')).toBeNull();
  });

  it('serializes query params using current contract field names', async () => {
    let capturedUrl = '';
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input) => {
        capturedUrl = String(input);
        return jsonResponse({ data: [] });
      },
    });

    await client.listIssues({
      projectId: '550e8400-e29b-41d4-a716-446655440000',
      state: 'in_progress',
      assigneeId: '660e8400-e29b-41d4-a716-446655440000',
    });

    expect(capturedUrl).toContain('projectId=550e8400-e29b-41d4-a716-446655440000');
    expect(capturedUrl).toContain('state=in_progress');
    expect(capturedUrl).toContain('assigneeId=660e8400-e29b-41d4-a716-446655440000');
  });
});
