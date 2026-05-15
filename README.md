# powerbi-mcp-proxy

A self-hosted MCP (Model Context Protocol) server that proxies **Claude**, **ChatGPT**, **GitHub Copilot CLI**, and other MCP clients to **Power BI** — using your own Entra tenant, your own Azure subscription. A drop-in workaround for Microsoft's broken hosted endpoint.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![FastMCP 3.x](https://img.shields.io/badge/fastmcp-3.x-green.svg)](https://github.com/jlowin/fastmcp)

---

## The problem

Microsoft's hosted Power BI MCP endpoint at `api.fabric.microsoft.com/v1/mcp/powerbi` has been broken since early 2026:

```
AADSTS9010010: The resource parameter provided in the request
               doesn't match with the requested scopes
```

The discovery response emits a `resourceUrl` field that conflicts with the requested scopes against Entra's v2 endpoint. Every OAuth attempt fails — Claude, ChatGPT, Copilot CLI, all of them. See [microsoft/powerbi-modeling-mcp#68](https://github.com/microsoft/powerbi-modeling-mcp/issues/68) for the full thread.

## What this is

A 250-line self-hosted server that:

- Runs its own OAuth proxy via FastMCP's `AzureProvider` — never emits the offending `resourceUrl` field.
- Each user signs in with their own Microsoft account.
- Per-request **On-Behalf-Of** token exchange — Power BI RLS applies per user, no shared service account.
- Single-tenant, enforced at startup (multi-tenant configs are rejected).
- Terraform spins up the whole thing on Azure App Service in one apply.

## What this is **not**

- **Not a managed service.** You bring your own Entra app registration and your own Azure hosting.
- **Not multi-tenant.** Each deployment serves one Entra tenant. (You can run several copies.)
- **Not a drop-in replacement for the Microsoft endpoint** in the "zero-setup" sense. It is a drop-in replacement in the "actually works" sense.

## Tools exposed

| Tool | Purpose |
|------|---------|
| `list_workspaces` | Workspaces the signed-in user can see |
| `list_datasets` | Datasets in a workspace |
| `run_dax_query` | Arbitrary `EVALUATE …` DAX against a dataset, as the user |
| `list_measures`, `list_columns` | Stubs — schema enumeration is unsupported on imported datasets; the stubs explain why and suggest `run_dax_query` probes |

Deliberately narrow. Build your own `@mcp.tool()` functions on top of `run_dax_query` for domain-specific reports.

## Architecture

```
MCP client (Claude / ChatGPT / Copilot)
       │  HTTPS
       ▼
  This server  ── AzureProvider OAuth proxy ──▶ login.microsoftonline.com
       │
       └── Per-request OBO exchange (azure-identity)
              │
              ▼
       Power BI REST API
       (queries run with the user's RLS — no service account)
```

Full auth flow and component breakdown in [docs/architecture.md](docs/architecture.md).

## Quick start

### Prerequisites

- An **Azure subscription** with admin rights to create app registrations
- **Power BI tenant setting** "Dataset Execute Queries REST API" enabled
- **Terraform** `>= 1.5.0`
- **Python** `3.11+` (for local development only)
- A **GitHub repo** you'll push the code to (for the included CI/CD)

### 1. Configure and apply Terraform

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set subscription_id, tenant_id, github_repo, owner
terraform init
terraform plan        # review every resource before applying
terraform apply
```

When apply succeeds, Terraform prints a `next_steps` output that walks you through the remaining manual steps.

### 2. Grant admin consent

Portal → Entra ID → App registrations → `<your-project>-server` → API permissions → **Grant admin consent**.

### 3. Add the GitHub Actions secrets

`terraform output github_actions_secrets` prints the three values. Add them to **Settings → Secrets and variables → Actions → New repository secret**:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

If you renamed `project_name` away from the default `pbi-mcp`, also add **repo variables** (same page, **Variables** tab):

- `AZURE_APP_NAME` = your `project_name`
- `AZURE_RESOURCE_GROUP` = your `project_name` + `-rg`

### 4. (Strongly recommended) Configure Conditional Access

Your Entra app's sign-in surface is now exposed to the public internet. Without Conditional Access (or at minimum MFA), one phished password gives an attacker OBO'd Power BI access to that user.

See [docs/azure-setup.md#conditional-access](docs/azure-setup.md#conditional-access) for the policy. Scope it to the new app registration — it won't affect anything else in your tenant.

### 5. Deploy

Run the **Build and Deploy** GitHub Actions workflow manually. It zips the source, authenticates to Azure via OIDC (no long-lived deploy creds), and rolls out via `az webapp deploy`.

### 6. Connect a client

Add the MCP endpoint to your client's custom connector configuration:

```
https://<your-project-name>.azurewebsites.net/mcp
```

(Replace `<your-project-name>` with whatever you set in `terraform.tfvars`.) First connection triggers a one-time OAuth consent prompt per user.

## Local development

```bash
python -m venv .venv
.venv\Scripts\activate                  # Windows
# source .venv/bin/activate              # macOS/Linux

pip install -r requirements.txt
cp .env.example .env                     # fill in your values
uvicorn pbi_mcp_remote:app --host 127.0.0.1 --port 8000
```

For testing against a real MCP client locally, expose `localhost:8000` via `ngrok http 8000` (or your tunnel of choice) and update `MCP_SERVER_URL` to the public URL. Remember to add the tunnel's callback to `MCP_ALLOWED_REDIRECT_URIS` if you're not using Claude.ai.

## Cost

The default Terraform path runs on **Azure App Service B1 Linux** (~$13/month). Key Vault is a few cents. GitHub Actions OIDC is free.

To run cheaper: deploy the Docker image to a smaller host (Fly.io, Railway, a $5 VPS) — see the included [Dockerfile](Dockerfile). You lose the Key Vault wiring and have to manage secrets yourself; read [SECURITY.md](SECURITY.md) first.

## Documentation

| File | What's in it |
|------|--------------|
| [docs/architecture.md](docs/architecture.md) | Auth + data flow, components, network surface |
| [docs/azure-setup.md](docs/azure-setup.md) | Admin consent, Conditional Access, Power BI tenant settings, GitHub Actions secrets |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common errors and what they actually mean |
| [SECURITY.md](SECURITY.md) | Threat model, enforced guards, recommended hardening |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose changes |

## Contributing

PRs welcome — especially for **additional verified MCP client redirect URI patterns** (ChatGPT, Copilot CLI, Cursor, etc.). Verify in your own tenant first, then open a PR with the pattern and a note on how you tested it.

Out of scope: domain-specific report tools. Keep your business logic in your own fork. The goal here is a small, auditable surface that as many people as possible can deploy with confidence.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Related

- [microsoft/powerbi-modeling-mcp#68](https://github.com/microsoft/powerbi-modeling-mcp/issues/68) — the upstream bug this works around
- [jlowin/fastmcp](https://github.com/jlowin/fastmcp) — the MCP framework
- [modelcontextprotocol.io](https://modelcontextprotocol.io) — protocol spec

## License

MIT — see [LICENSE](LICENSE).
