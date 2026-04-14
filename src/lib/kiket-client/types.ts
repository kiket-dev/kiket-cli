export type AuthMode =
  | { kind: 'jwt'; token: string }
  | { kind: 'apiKey'; apiKey: string };

export interface KiketClientOptions {
  baseUrl: string;
  auth?: AuthMode;
  organizationId?: string;
  userAgent?: string;
  fetchImpl?: typeof fetch;
}

export interface RequestOptions {
  searchParams?: URLSearchParams | Record<string, string | number | boolean | undefined | null>;
  headers?: Record<string, string>;
  body?: unknown;
}

export interface LoginResult {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  user: {
    id: string;
    email: string;
    name: string;
  };
}

export interface SelectOrganizationResult {
  selectOrganization: true;
  userId: string;
  organizations: Array<{
    id: string;
    name: string;
    slug: string;
    role: string;
  }>;
}

export type LoginResponse = LoginResult | SelectOrganizationResult;
