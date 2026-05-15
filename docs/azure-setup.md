# Azure Setup Guide

Manual steps that complement `terraform apply`. The Terraform sets up the infrastructure; these steps configure things Terraform can't (or shouldn't) automate.

## 1. Grant admin consent for the Power BI permission

After `terraform apply` succeeds:

1. **Azure Portal → Entra ID → App registrations** → find `<project_name>-server`
2. **API permissions**
3. Click **Grant admin consent for `<your-tenant>`** and confirm

This authorizes the app to request `Dataset.Read.All` on behalf of users. Without it, every user sees an "admin consent required" error on first sign-in.

## 2. Optional GitHub Actions deployment

This public repository does not include a live deployment workflow. If you want
GitHub Actions deployment from your own repo, see
[github-actions-deploy.md](github-actions-deploy.md).

To enable Terraform's optional OIDC resources, set:

```hcl
enable_github_actions_deploy = true
github_repo                  = "your-handle/your-repo"
```

Then run `terraform apply` and add the `github_actions_secrets` output as repository secrets:

| Secret | Source |
|--------|--------|
| `AZURE_CLIENT_ID` | `github_actions_secrets.AZURE_CLIENT_ID` |
| `AZURE_TENANT_ID` | `github_actions_secrets.AZURE_TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `github_actions_secrets.AZURE_SUBSCRIPTION_ID` |

If you set `project_name` to anything other than the default `pbi-mcp`, also add **Repository variables** (same page, **Variables** tab):

| Variable | Value |
|----------|-------|
| `AZURE_APP_NAME` | Your `project_name` (e.g. `acme-pbi-mcp`) |
| `AZURE_RESOURCE_GROUP` | Your `project_name` + `-rg` (e.g. `acme-pbi-mcp-rg`) |

## 3. Conditional Access

> **Why this matters:** your Entra app's sign-in surface is now reachable from the public internet. Without Conditional Access (or at minimum MFA), one phished password in your tenant gives an attacker delegated Power BI access to that user. Scope the policy to the new MCP app only — it will not affect anything else in your tenant.

### Step 1 — Named location

1. **Entra ID → Security → Named locations**
2. **+ IP ranges location**
3. Name: e.g. `MCP trusted IPs`
4. Check **Mark as trusted location**
5. Add your CIDR ranges (e.g. `203.0.113.0/24`)
6. **Create**

### Step 2 — Conditional Access policy

1. **Entra ID → Security → Conditional Access → Policies → + New policy**
2. Name: `PBI MCP — block outside trusted IPs`
3. **Assignments → Users**: All users in your tenant (or a specific security group of MCP users)
4. **Assignments → Target resources → Cloud apps → Include**: select `<project_name>-server`
5. **Assignments → Conditions → Locations**:
   - Configure: **Yes**
   - Include: **Any location**
   - Exclude: **Selected locations → MCP trusted IPs**
6. **Access controls → Grant**: pick one based on your posture:
   - **Block access** — strictest. Sign-in from outside trusted IPs is refused entirely.
   - **Grant access with MFA required** — softer. Sign-in still works from anywhere but requires MFA outside trusted IPs.
7. **Enable policy**: On
8. **Create**

### Verify

- Sign-in attempt from outside the trusted range → blocked (or MFA-prompted)
- Sign-in from inside → succeeds

## 4. Power BI tenant settings

In **Power BI Admin Portal → Tenant settings**, verify:

- **Dataset Execute Queries REST API** — must be enabled (or scoped to a group that includes your users) for `run_dax_query` to work. This is the most common cause of `403 Forbidden` on the first query.
- **Service principals can use Fabric APIs** — not required for delegated (per-user) auth, but if you have a tenant-wide block on it, confirm it does not extend to your security group.

## 5. Verify deployment

After deploying the app code:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-project-name>.azurewebsites.net/mcp
# Expected: 401 (unauthenticated) or 405 (method not allowed) — both mean the server is up
```

If you see `200` or `404`, something else is wrong — check [troubleshooting.md](troubleshooting.md).
