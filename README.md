# `@kiket/cli`

Modern TypeScript CLI for Kiket. It targets the operational compliance platform API and local `.kiket/` configuration files.

## Strategy

The new CLI is intentionally narrow and honest:

- it exposes only the workspace/process/case/evidence/finding/report/anchor platform loop
- it uses the shared `@kiket/api-client` contract layer
- it is non-interactive by default and supports machine-readable output
- it validates and migrates file-backed `.kiket/` configuration locally when possible

## Future Vision

- generated contracts from OpenAPI for tighter drift prevention
- richer interactive auth and organization selection flows
- repo-aware config helpers for process modeling
- full parity for supported platform capabilities as those APIs land

## Current Scope

- `kiket init`
- `kiket validate`
- `kiket migrate-config`
- `kiket simulate`
- `kiket scan`
- `kiket findings list`
- `kiket evidence import`
- `kiket report generate`
- `kiket report verify`
- `kiket anchor create`
- `kiket anchor verify`
- `kiket extension test`

## Development

```bash
pnpm install
pnpm test
pnpm check
pnpm lint
pnpm build
```
