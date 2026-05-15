# Troubleshooting

Common errors and what they actually mean. Roughly in the order you'll hit them.

## Terraform apply

### `Error: The vault name '<name>-kv' is already in use`

Key Vault names are tenant-global. Someone in your tenant (possibly you, in a previous attempt) has used it. Either:

- Set a different `project_name` in `terraform.tfvars`, or
- Run `az keyvault purge --name <name>-kv` to recover a soft-deleted vault you own

### `Error: The app name '<name>' is not available`

Same as above but for App Service. App Service names are *globally* unique (not just per-tenant). Pick a more specific `project_name`, e.g. `acme-pbi-mcp`.

### `Error: Insufficient privileges to complete the operation`

Your account doesn't have **Application Administrator** (or higher) in Entra ID. The Terraform creates app registrations, which requires elevated permissions. Either get the role assigned or have an admin run `terraform apply` once.

### Setting up remote tfstate

Local tfstate contains the client secret in plaintext. For anything beyond an evaluation, configure a remote backend before first apply:

```bash
# Create the backend storage account first (one-time, manual)
az group create --name tfstate-rg --location eastus2
az storage account create --name <unique-name> --resource-group tfstate-rg --sku Standard_LRS --allow-blob-public-access false
az storage container create --name tfstate --account-name <unique-name> --auth-mode login
```

Then uncomment and fill in the `backend "azurerm"` block in [infra/providers.tf](../infra/providers.tf) before running `terraform init`. If you already ran `apply` with local state, run `terraform init -migrate-state` to move it.

## Admin consent

### Users see "admin consent required" on first sign-in

You skipped step 1 of [azure-setup.md](azure-setup.md). Portal → Entra ID → App registrations → `<project_name>-server` → API permissions → **Grant admin consent**.

### `Grant admin consent` button is greyed out

You don't have **Privileged Role Administrator** or **Global Administrator**. A tenant admin needs to do it.

## OAuth handshake (the AADSTS9010010 family)

### `AADSTS9010010` — but I'm using this proxy, not Microsoft's hosted one

This error means *some* component in the chain is appending a `resource` parameter to a v2 authorize request. If you see it from `powerbi-mcp-proxy`, check:

1. `PBI_TENANT_ID` is a specific GUID, not `common` (verify with `az webapp config appsettings list ...`)
2. You're hitting `https://<your-app>.azurewebsites.net/mcp`, not the Microsoft endpoint
3. Some MCP clients cache discovery metadata — clear the client's stored connector and re-add it

### `AADSTS50011: The reply URL specified in the request does not match`

The redirect URI the MCP client used isn't in your app registration's allowlist. Either:

- The Terraform should have set this to `https://<your-app>.azurewebsites.net/auth/callback` — check the app registration's **Authentication** blade
- Your `MCP_SERVER_URL` env var doesn't match the actual deployed URL (e.g. you set it to `https://example.com` but deployed to `https://pbi-mcp.azurewebsites.net`)

### `AADSTS65001: The user or administrator has not consented`

Same as the admin consent issue above — step 1 of [azure-setup.md](azure-setup.md) wasn't completed.

## Server startup

### `RuntimeError: PBI_TENANT_ID='common' is multi-tenant...`

You set `PBI_TENANT_ID` to `common`, `organizations`, or `consumers`. These disable issuer validation. Set it to your tenant GUID. (See [SECURITY.md](../SECURITY.md) Required configuration #1.)

### `RuntimeError: MCP_SERVER_URL='http://example.com' uses http:// on a non-localhost host`

You're trying to deploy with plaintext HTTP, which would leak OAuth tokens. Use `https://`. For local dev, `http://localhost:8000` is allowed.

### `RuntimeError: MCP_ALLOWED_REDIRECT_URIS must list specific client callbacks...`

You set `MCP_ALLOWED_REDIRECT_URIS=*` (or empty). A bare `*` allows DCR clients to register any redirect URI and intercept tokens. Use specific patterns like `https://claude.ai/api/mcp/*`.

## CI/CD

### GitHub Actions smoke test fails with `HTTP 000` repeatedly

The App Service hasn't finished starting up. The workflow waits 12 × 15 seconds = 3 minutes. Cold starts on B1 with package installation can occasionally exceed that. Re-run the job; if it consistently times out, check the App Service log stream for installation errors.

### Smoke test passes but the MCP client says "Couldn't reach the MCP server"

The endpoint is `/mcp`, not `/`. Verify the URL ends in `/mcp` exactly. If it does, check that the App Service is serving from `pbi_mcp_remote:app` — the startup command is set by Terraform but can drift if someone edits the App Service config.

### `gh: deployment failed — Status: Conflict`

App Service is mid-deploy. The previous workflow run is still publishing. Wait or cancel and re-run.

## Power BI calls

### `401 Unauthorized` on `list_workspaces` after a successful sign-in

The user signed in fine but doesn't have **Power BI Pro** (or doesn't have any workspaces yet). Per-user data calls require Pro. Add a Pro license or wait for the user's admin to assign one.

### `403 Forbidden` on `run_dax_query`

Most likely: tenant setting **Dataset Execute Queries REST API** is disabled, or scoped to a group the user isn't in. Power BI Admin Portal → Tenant settings → enable for "specific security groups" and include the user.

### `400 Bad Request` on `run_dax_query` with "Query (1, X) ..."

DAX syntax error. The error position is character-indexed. Common: forgetting `EVALUATE`, wrong column-reference syntax (`'Table'[Column]` not `Table.Column`), or a measure that doesn't exist.

## Cost surprises

### Bill jumped

The Linux Web App B1 is fixed-price, but Key Vault egress + Log Analytics + Application Insights (if you added them) can creep up. Check `az consumption usage list` or the Azure Cost Management blade. The vanilla template should run ~$13/month all-in.
