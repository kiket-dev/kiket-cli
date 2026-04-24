import { z } from 'zod';
import { KiketClientError } from './errors.js';
import {
  commentListSchema,
  commentSchema,
  currentUserSchema,
  issueListSchema,
  issueSchema,
  issueTypeListSchema,
  milestoneListSchema,
  milestoneSchema,
  organizationListSchema,
  organizationSchema,
  projectListSchema,
  projectSchema,
  templateDefinitionListSchema,
  templateDefinitionSchema,
  transitionResultSchema,
  workflowListSchema,
  workflowSchema,
  workflowValidationSchema,
} from './schemas.js';
import type { KiketClientOptions, LoginResponse, RequestOptions } from './types.js';

const loginResponseSchema = z.union([
  z.object({
    accessToken: z.string(),
    refreshToken: z.string(),
    expiresIn: z.number(),
    user: z.object({
      id: z.string().uuid(),
      email: z.string().email(),
      name: z.string(),
    }),
  }),
  z.object({
    selectOrganization: z.literal(true),
    userId: z.string().uuid(),
    organizations: z.array(
      z.object({
        id: z.string().uuid(),
        name: z.string(),
        slug: z.string(),
        role: z.string(),
      }),
    ),
  }),
]);

function withSearchParams(path: string, searchParams?: RequestOptions['searchParams']): string {
  if (!searchParams) return path;
  const params = searchParams instanceof URLSearchParams ? searchParams : new URLSearchParams();

  if (!(searchParams instanceof URLSearchParams)) {
    for (const [key, value] of Object.entries(searchParams)) {
      if (value === undefined || value === null || value === '') continue;
      params.set(key, String(value));
    }
  }

  const query = params.toString();
  return query ? `${path}?${query}` : path;
}

export class KiketClient {
  private readonly baseUrl: string;
  private readonly auth?: KiketClientOptions['auth'];
  private readonly organizationId?: string;
  private readonly fetchImpl: typeof fetch;
  private readonly userAgent: string;

  constructor(options: KiketClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.auth = options.auth;
    this.organizationId = options.organizationId;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.userAgent = options.userAgent ?? '@kiket/client';
  }

  withAuth(auth: KiketClientOptions['auth'], organizationId = this.organizationId): KiketClient {
    return new KiketClient({
      baseUrl: this.baseUrl,
      auth,
      organizationId,
      fetchImpl: this.fetchImpl,
      userAgent: this.userAgent,
    });
  }

  async login(email: string, password: string): Promise<LoginResponse> {
    return this.request('/api/v1/auth/login', {
      method: 'POST',
      body: { email, password },
      schema: loginResponseSchema,
      includeAuth: false,
    });
  }

  async selectOrganization(userId: string, organizationId: string): Promise<z.infer<typeof loginResponseSchema>> {
    return this.request('/api/v1/auth/login/select-org', {
      method: 'POST',
      body: { userId, organizationId },
      schema: loginResponseSchema,
      includeAuth: false,
    });
  }

  async getCurrentUser() {
    return this.request('/api/v1/auth/me', { schema: currentUserSchema });
  }

  async getHealth() {
    return this.request('/health', {
      schema: z.object({
        status: z.literal('ok'),
        version: z.string(),
        timestamp: z.string(),
      }),
      includeAuth: false,
    });
  }

  async listOrganizations() {
    return this.request('/api/v1/organizations', { schema: organizationListSchema }).then((body) => body.data);
  }

  async getOrganization(orgId: string) {
    return this.request(`/api/v1/organizations/${orgId}`, { schema: organizationSchema });
  }

  async listProjects(orgId: string) {
    return this.request(`/api/v1/organizations/${orgId}/projects`, { schema: projectListSchema }).then(
      (body) => body.data,
    );
  }

  async getProject(orgId: string, projectId: string) {
    return this.request(`/api/v1/organizations/${orgId}/projects/${projectId}`, { schema: projectSchema });
  }

  async createProject(orgId: string, input: { name: string; key: string; description?: string }) {
    return this.request(`/api/v1/organizations/${orgId}/projects`, {
      method: 'POST',
      body: input,
      schema: projectSchema,
    });
  }

  async updateProject(orgId: string, projectId: string, input: { name?: string; description?: string }) {
    return this.request(`/api/v1/organizations/${orgId}/projects/${projectId}`, {
      method: 'PATCH',
      body: input,
      schema: projectSchema,
    });
  }

  async deleteProject(orgId: string, projectId: string) {
    return this.request(`/api/v1/organizations/${orgId}/projects/${projectId}`, {
      method: 'DELETE',
      schema: z.object({ message: z.string() }),
    });
  }

  async listIssues(filters: { projectId?: string; state?: string; assigneeId?: string }) {
    return this.request('/api/v1/issues', {
      searchParams: filters,
      schema: issueListSchema,
    }).then((body) => body.data);
  }

  async getIssue(issueId: string) {
    return this.request(`/api/v1/issues/${issueId}`, {
      schema: issueSchema.extend({ transitions: z.array(z.unknown()).optional() }),
    });
  }

  async createIssue(input: {
    workflowKey: string;
    workflowRepoId?: string;
    projectId?: string;
    title: string;
    description?: string;
    assigneeId?: string;
    priority?: 'low' | 'medium' | 'high' | 'critical';
    issueType?: string;
    dueDate?: string;
    milestoneId?: string;
    labels?: string[];
    customFields?: Record<string, unknown>;
  }) {
    return this.request('/api/v1/issues', {
      method: 'POST',
      body: input,
      schema: issueSchema,
    });
  }

  async transitionIssue(issueId: string, targetState: string) {
    return this.request(`/api/v1/issues/${issueId}/transition`, {
      method: 'POST',
      body: { targetState },
      schema: transitionResultSchema,
    });
  }

  async listIssueTypes() {
    return this.request('/api/v1/issue-types', { schema: issueTypeListSchema }).then((body) => body.data);
  }

  async listMilestones(projectId: string) {
    return this.request('/api/v1/milestones', {
      searchParams: { projectId },
      schema: milestoneListSchema,
    }).then((body) => body.data);
  }

  async getMilestone(milestoneId: string) {
    return this.request(`/api/v1/milestones/${milestoneId}`, { schema: milestoneSchema });
  }

  async createMilestone(input: {
    projectId: string;
    title: string;
    description?: string;
    dueDate?: string;
    status?: 'open' | 'closed';
  }) {
    return this.request('/api/v1/milestones', {
      method: 'POST',
      body: input,
      schema: milestoneSchema,
    });
  }

  async updateMilestone(
    milestoneId: string,
    input: {
      title?: string;
      description?: string | null;
      dueDate?: string | null;
      status?: 'open' | 'closed';
    },
  ) {
    return this.request(`/api/v1/milestones/${milestoneId}`, {
      method: 'PATCH',
      body: input,
      schema: milestoneSchema,
    });
  }

  async deleteMilestone(milestoneId: string) {
    return this.request(`/api/v1/milestones/${milestoneId}`, {
      method: 'DELETE',
      schema: z.object({ deleted: z.boolean() }),
    });
  }

  async listComments(issueId: string) {
    return this.request(`/api/v1/issues/${issueId}/comments`, { schema: commentListSchema }).then((body) => body.data);
  }

  async createComment(issueId: string, body: string, parentId?: string) {
    return this.request(`/api/v1/issues/${issueId}/comments`, {
      method: 'POST',
      body: { body, parentId },
      schema: commentSchema,
    });
  }

  async updateComment(issueId: string, commentId: string, body: string) {
    return this.request(`/api/v1/issues/${issueId}/comments/${commentId}`, {
      method: 'PATCH',
      body: { body },
      schema: commentSchema,
    });
  }

  async deleteComment(issueId: string, commentId: string) {
    return this.request(`/api/v1/issues/${issueId}/comments/${commentId}`, {
      method: 'DELETE',
      schema: z.object({ message: z.string() }),
    });
  }

  async listWorkflows(projectId?: string) {
    return this.request('/api/v1/workflows', {
      searchParams: { projectId },
      schema: workflowListSchema,
    }).then((body) => body.data);
  }

  async getWorkflow(workflowId: string) {
    return this.request(`/api/v1/workflows/${workflowId}`, { schema: workflowSchema });
  }

  async validateWorkflow(yaml: string) {
    return this.request('/api/v1/workflows/validate', {
      method: 'POST',
      body: { yaml },
      schema: workflowValidationSchema,
    });
  }

  async listDefinitions() {
    return this.request('/api/v1/templates/catalog', { schema: templateDefinitionListSchema }).then(
      (body) => body.templates,
    );
  }

  async getDefinition(key: string) {
    return this.request(`/api/v1/templates/catalog/${key}`, { schema: templateDefinitionSchema });
  }

  async getWorkflowYaml(workflowId: string): Promise<string> {
    const response = await this.fetchImpl(`${this.baseUrl}/api/v1/workflows/${workflowId}/yaml`, {
      method: 'GET',
      headers: this.headers(),
    });
    if (!response.ok) {
      throw await this.buildError(response);
    }
    return response.text();
  }

  private headers(extra: Record<string, string> = {}, includeAuth = true): Record<string, string> {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'User-Agent': this.userAgent,
      ...extra,
    };

    if (includeAuth && this.auth) {
      if (this.auth.kind === 'jwt') headers.Authorization = `Bearer ${this.auth.token}`;
      if (this.auth.kind === 'apiKey') headers['X-API-Key'] = this.auth.apiKey;
    }

    if (this.organizationId) {
      headers['X-Organization-Id'] = this.organizationId;
    }

    return headers;
  }

  private async request<TSchema extends z.ZodTypeAny>(
    path: string,
    options: {
      method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
      searchParams?: RequestOptions['searchParams'];
      body?: unknown;
      headers?: Record<string, string>;
      schema: TSchema;
      includeAuth?: boolean;
    },
  ): Promise<z.infer<TSchema>> {
    const url = `${this.baseUrl}${withSearchParams(path, options.searchParams)}`;
    const response = await this.fetchImpl(url, {
      method: options.method ?? 'GET',
      headers: this.headers(options.headers, options.includeAuth ?? true),
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });

    if (!response.ok) {
      throw await this.buildError(response);
    }

    const json = (await response.json()) as unknown;
    return options.schema.parse(json);
  }

  private async buildError(response: Response): Promise<KiketClientError> {
    const payload = await response.json().catch(() => null);
    const message =
      payload && typeof payload === 'object' && payload !== null && ('error' in payload || 'message' in payload)
        ? (payload as { error?: { message?: string } | string; message?: string }).error &&
          typeof (payload as { error?: { message?: string } | string }).error === 'object'
          ? ((payload as { error: { message?: string } }).error.message ?? `Request failed with ${response.status}`)
          : ((payload as { error?: string; message?: string }).error ??
            (payload as { message?: string }).message ??
            `Request failed with ${response.status}`)
        : `Request failed with ${response.status}`;

    return new KiketClientError(message, response.status, payload);
  }
}
