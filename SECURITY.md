# Security

This is a reference implementation, not a managed service. Read this file before deploying. The pattern is sound, but the defaults that protect you live in your Entra configuration and your hosting choices — not in this repo.

## Threat model

This server:

- Is **exposed to the public internet** (necessary — MCP clients sign in via HTTPS).
- Holds an **Entra app client secret** that, combined with a user's delegated token, performs OAuth On-Behalf-Of exchange to mint Power BI tokens for that user.
- Issues short-lived JWTs to MCP clients (signed with `JWT_SIGNING_KEY`) that prove authentication.

The blast radius of a compromise:

- **Client secret leak (production):** an attacker with the secret + a phished user token can mint Power BI tokens for that user. Scoped to one user at a time (OBO doesn't bypass user identity), but very bad.
- **Server compromise (RCE/full host):** attacker can mint tokens for every user who is actively signed in. Refresh tokens are stored Fernet-encrypted at rest but the key is on the host.
- **DCR bypass (wide redirect allowlist):** attacker registers as a client with their own redirect URI and intercepts user tokens at consent time.

What protects you:

- Single-tenant Entra app (enforced in code; multi-tenant tenant IDs are rejected at startup).
- The OAuth provider validates issuer, audience, signature, expiry, and scopes on every JWT.
- OBO uses `azure-identity`, not hand-rolled crypto.
- Power BI RLS still gates every query — a server compromise doesn't grant access the affected user wouldn't already have.

## Required configuration (not optional)

The template enforces these at startup; do not work around them:

1. **`PBI_TENANT_ID` must be a specific tenant GUID.** `common`, `organizations`, `consumers`, and empty are rejected because FastMCP's `AzureProvider` skips issuer validation in those modes, allowing any Microsoft account to authenticate.
2. **`MCP_SERVER_URL` must use `https://` for any non-localhost host.** Plaintext HTTP would leak OAuth tokens.
3. **`MCP_ALLOWED_REDIRECT_URIS` must be specific patterns, never bare `*`.** Path wildcards (`https://claude.ai/api/mcp/*`) are fine. A bare `*` lets an attacker register a client whose redirect URI intercepts user tokens.

## Strongly recommended (not enforced)

These are on you. Skipping them does not stop the server from running, but it materially raises your risk:

- **Conditional Access on the app registration.** Restrict sign-in to trusted IPs / device compliance / MFA. The server's Entra app surface is internet-exposed; phishing risk is real.
- **Key Vault for secrets.** The included Terraform wires `PBI_CLIENT_SECRET` and `JWT_SIGNING_KEY` to Key Vault via managed identity. If you deploy outside the Terraform path (e.g. a $5 VPS), do not put the client secret in `/etc/environment` or a `.env` on disk. Use a secret manager.
- **Don't share scale.** OBO credentials are cached in-memory per process by design. Do not add a Redis or other shared backing store — tokens would leave the process boundary. Run one replica.
- **Pin `fastmcp` and re-verify auth across major bumps.** This template is validated against `fastmcp[azure]>=3.0.0,<4.0.0`. Auth-provider behavior has changed between major versions in the past; treat upgrades as a security event.

## What `run_dax_query` can do

`run_dax_query` is — by design — arbitrary DAX execution as the signed-in user against any dataset they have access to. This is the whole point of the tool, but it is worth being clear: connecting an MCP client to this server is equivalent to granting that client the user's Power BI read access. Tell your users that.

## Known limitations in upstream dependencies

From the security review of FastMCP `AzureProvider` (April 2026, against `PrefectHQ/fastmcp` main):

- **LOW** — JWT verifier does not enforce `nbf`/`iat` time claims (signature, expiry, audience, issuer, scopes all checked).
- **LOW** — `AzureProvider` always requests `offline_access` and stores refresh tokens server-side. Storage is Fernet-encrypted; the encryption key is in `JWT_SIGNING_KEY`.
- **INFO** — Issuer validation skipped if `tenant_id` is `common`/`organizations`/`consumers`. The template refuses to start in those modes (see Required configuration #1).

This template requires `fastmcp[azure] >= 3.0.0`, which transitively includes all known FastMCP CVE fixes (earliest CVE-fixed release: `2.13.0`). Treat any major version bump as a security event — re-verify the auth flow end-to-end against a throwaway tenant before upgrading.

## Reporting a vulnerability

Do not open a public issue for exploitable vulnerabilities or secret-handling flaws. Use GitHub private vulnerability reporting for this repository if it is enabled; otherwise contact the maintainer privately and include only enough detail to coordinate a safe disclosure.
