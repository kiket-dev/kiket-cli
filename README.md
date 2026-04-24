# `@kiket/cli`

Modern TypeScript CLI for Kiket. This replaces the legacy Ruby CLI with a standalone implementation that targets the current API only.

## Strategy

The new CLI is intentionally narrow and honest:

- it only exposes routes that actually exist in the API
- it uses a typed in-repo client contract layer for standalone reliability
- it favors pure, testable helpers over hidden command-side state
- it treats extension scaffolding as a first-class product surface, not an afterthought

## Future Vision

- generated contracts from OpenAPI for tighter drift prevention
- richer interactive auth and organization selection flows
- project/workflow editor helpers and repo-aware local tooling
- full parity for supported platform capabilities as those APIs land

## Current Scope

- authentication
- health/doctor
- projects (list/show)
- issues (list/show/create/transition + issue types)
- milestones (list/show)
- workflows (list/validate)
- definitions (list/show)
- extension scaffolding for `node`, `python`, `ruby`, `java`, `dotnet`, `go`

## Development

```bash
pnpm install
pnpm test
pnpm check
pnpm lint
pnpm build
```
