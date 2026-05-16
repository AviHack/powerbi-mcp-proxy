## What this changes

<!-- One or two sentences. -->

## Why

<!-- The motivation. Link the issue if there is one. -->

## How I verified

<!-- Be specific. "Tested locally" doesn't tell us what to expect. -->
- [ ] Import smoke test passes (`python -c "import pbi_mcp_remote"` with placeholder env vars)
- [ ] `terraform validate` passes (if you touched `infra/`)
- [ ] (If applicable) end-to-end OAuth handshake with an MCP client succeeds

## Anything reviewers should look at carefully

<!-- e.g. "I changed the OBO cache key derivation — please sanity-check it doesn't open a cross-user reuse hole." -->
