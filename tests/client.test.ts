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

  it('uses canonical milestones by-id endpoint', async () => {
    let capturedUrl = '';
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input) => {
        capturedUrl = String(input);
        return jsonResponse({
          id: '550e8400-e29b-41d4-a716-446655440000',
          organizationId: '770e8400-e29b-41d4-a716-446655440000',
          projectId: '880e8400-e29b-41d4-a716-446655440000',
          title: 'Milestone',
          description: null,
          dueDate: null,
          status: 'open',
          createdAt: '2026-01-01T00:00:00.000Z',
          updatedAt: '2026-01-01T00:00:00.000Z',
        });
      },
    });

    await client.getMilestone('550e8400-e29b-41d4-a716-446655440000');
    expect(capturedUrl).toContain('/api/v1/milestones/550e8400-e29b-41d4-a716-446655440000');
  });

  it('uses canonical org-scoped projects endpoint', async () => {
    let captured: Request | undefined;
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input, init) => {
        captured = new Request(input, init);
        return jsonResponse({ data: [] });
      },
    });

    await client.listProjects('770e8400-e29b-41d4-a716-446655440000');
    expect(captured?.method).toBe('GET');
    expect(captured?.url).toContain('/api/v1/organizations/770e8400-e29b-41d4-a716-446655440000/projects');
  });

  it('uses canonical transition endpoint and payload', async () => {
    let captured: Request | undefined;
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input, init) => {
        captured = new Request(input, init);
        return jsonResponse({
          issue: {
            id: '550e8400-e29b-41d4-a716-446655440000',
            projectId: '550e8400-e29b-41d4-a716-446655440111',
            workflowKey: 'kanban',
            workflowRepoId: null,
            number: 1,
            title: 'Issue',
            description: null,
            currentState: 'done',
            assigneeId: null,
            assigneeName: null,
            reporterId: '550e8400-e29b-41d4-a716-446655440222',
            reporterName: null,
            priority: 'medium',
            issueType: null,
            dueDate: null,
            milestoneId: null,
            milestoneName: null,
            labels: [],
            customFields: {},
            parentId: null,
            subtaskIds: [],
            workflow: null,
            sla: null,
            createdAt: '2026-01-01T00:00:00.000Z',
            updatedAt: '2026-01-01T00:00:00.000Z',
          },
          from: 'in_progress',
          to: 'done',
          intents: [],
        });
      },
    });

    await client.transitionIssue('550e8400-e29b-41d4-a716-446655440000', 'done');
    expect(captured?.method).toBe('POST');
    expect(captured?.url).toContain('/api/v1/issues/550e8400-e29b-41d4-a716-446655440000/transition');
    const body = (await captured?.json()) as { targetState: string };
    expect(body.targetState).toBe('done');
  });

  it('uses canonical definitions catalog endpoint', async () => {
    let capturedUrl = '';
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input) => {
        capturedUrl = String(input);
        return jsonResponse({ templates: [] });
      },
    });

    await client.listDefinitions();
    expect(capturedUrl).toContain('/api/v1/templates/catalog');
  });

  it('uses canonical definition detail endpoint', async () => {
    let capturedUrl = '';
    const client = new KiketClient({
      baseUrl: 'https://example.test',
      fetchImpl: async (input) => {
        capturedUrl = String(input);
        return jsonResponse({
          key: 'healthcare',
          name: 'Healthcare',
          description: 'Healthcare workflows',
          category: 'healthcare',
          workflowCount: 1,
          boardCount: 1,
          issueTypeCount: 1,
          hasIntakeForms: false,
          previewStates: ['intake'],
          onboardingRoles: [],
          files: [],
        });
      },
    });

    await client.getDefinition('healthcare');
    expect(capturedUrl).toContain('/api/v1/templates/catalog/healthcare');
  });
});
