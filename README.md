# `@kiket/cli`

Modern TypeScript CLI for Kiket — workspace/process/case/evidence/finding/report/anchor platform loop and local `.kiket/` validation.

## Role in the monorepo

Non-interactive, machine-readable client for the platform API. Uses `@kiket/api-client` for contract alignment. Submodule checkout: see [docs/architecture/submodules.md](../docs/architecture/submodules.md).

## Current scope

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

## Commands

```bash
pnpm --filter @kiket/cli test
pnpm --filter @kiket/cli check
pnpm --filter @kiket/cli lint
pnpm --filter @kiket/cli build
```

## Related docs

- [MCP server](../mcp/README.md) — agent-facing tools over the same API
- [API client](../packages/api-client/README.md)
- [CLI/MCP/SDK skill](../.cursor/skills/kiket-cli-mcp-sdk/SKILL.md)
- [Public CLI docs](https://docs.kiket.dev/docs/cli/overview) (docs-site)
