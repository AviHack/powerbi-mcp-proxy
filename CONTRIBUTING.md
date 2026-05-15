# Contributing

Thanks for your interest. This project deliberately has a small surface — keeping it that way is the contribution that matters most.

## What's in scope

- **Bug fixes** to the OAuth proxy, OBO exchange, or DAX query path
- **Additional verified MCP client redirect URI patterns** for the `MCP_ALLOWED_REDIRECT_URIS` documentation (ChatGPT, Copilot CLI, Cursor, etc.). PRs must include a note on how you verified the pattern in your own tenant.
- **Hosting recipes** for other targets (Fly.io, Railway, Container Apps) — as long as they document the secret-management story
- **Documentation improvements**, especially troubleshooting entries based on real errors you hit
- **Security hardening** — defensive defaults, additional guards, dependency upgrades

## What's out of scope

- **Domain-specific report tools.** Keep business logic in your own fork. The goal here is a small, auditable surface that as many people as possible can deploy with confidence. A repo full of someone's ERP-specific DAX queries doesn't serve that goal.
- **Multi-tenant support.** This template is intentionally single-tenant — see [SECURITY.md](SECURITY.md). PRs that re-enable `common`/`organizations`/`consumers` tenant IDs will be rejected unless they include a thorough threat-model update.
- **In-memory cache replacements with Redis/external stores.** The OBO cache is in-memory by design — tokens stay in process scope.
- **Removing the defensive startup guards.** They exist to prevent specific misconfigurations that are easy to make and hard to detect.

## Filing issues

Use the issue templates. The bug template asks for:

- Your MCP client and version
- Your `PBI_TENANT_ID` (just say "specific GUID" or "multi-tenant" — don't paste the real one)
- The exact error message, including the AADSTS code if any
- Whether you deployed via the included Terraform or another path

That information up front is the difference between "I can help" and "I need 6 round-trips of clarifying questions."

## Submitting PRs

1. **Open an issue first** for anything beyond a typo fix. A 10-minute discussion saves a 5-hour rewrite.
2. **One concern per PR.** Don't bundle a redirect-URI addition with a Terraform refactor.
3. **Run the import smoke test locally:**
   ```bash
   python -c "
   import os
   os.environ['PBI_CLIENT_ID']     = '00000000-0000-0000-0000-000000000000'
   os.environ['PBI_CLIENT_SECRET'] = 'placeholder'
   os.environ['PBI_TENANT_ID']     = '11111111-1111-1111-1111-111111111111'
   os.environ['JWT_SIGNING_KEY']   = 'placeholder-signing-key-for-local-smoke-test'
   os.environ['MCP_SERVER_URL']    = 'http://localhost:8000'
   import pbi_mcp_remote
   "
   ```
   The CI workflow does the same on every PR.
4. **Run linting locally:**
   ```bash
   ruff check .
   ```
5. **Don't add dependencies casually.** The runtime has five direct dependencies for a reason. If you need a sixth, explain in the PR description why.
6. **Update the docs** if you change behavior. README, SECURITY.md, troubleshooting — wherever applies.

## Code style

- Type hints on every function signature
- `log.info("key=value count=%d", count)` style, not f-strings for logs
- No comments that say *what* — only *why* something non-obvious is the way it is
- 100-char soft line length

## License

By contributing, you agree your contributions are licensed under the MIT License (see [LICENSE](LICENSE)).
