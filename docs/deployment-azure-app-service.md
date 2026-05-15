# Azure App Service Deployment

This is the recommended deployment path. It creates resources in your Azure
subscription and your Entra tenant; nothing deploys from the public upstream
repository.

## Prerequisites

- Azure subscription access that can create resource groups, App Service plans, Key Vaults, and role assignments.
- Entra permission to create app registrations, or an administrator who can run Terraform once.
- Terraform `>= 1.5.0`.
- Azure CLI authenticated to the target subscription.
- Power BI tenant setting **Dataset Execute Queries REST API** enabled for your users.

## 1. Configure Terraform

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Set at least:

```hcl
subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"
owner           = "your-name-or-team"
project_name    = "your-pbi-mcp"
```

`project_name` becomes the App Service hostname:

```text
https://<project_name>.azurewebsites.net/mcp
```

## 2. Apply Terraform

```bash
terraform init
terraform plan
terraform apply
```

For production use, configure a remote Terraform backend before the first
apply. Local Terraform state contains generated secrets.

## 3. Grant Admin Consent

In Azure Portal:

1. Entra ID -> App registrations.
2. Open `<project_name>-server`.
3. API permissions.
4. Grant admin consent.

Without this, users will hit an admin-consent error during first sign-in.

## 4. Deploy App Code

From the repository root:

```bash
python -m zipfile -c app.zip pbi_mcp_remote.py requirements.txt
az webapp deploy \
  --name <project_name> \
  --resource-group <project_name>-rg \
  --src-path app.zip \
  --type zip
```

Azure App Service installs `requirements.txt` during deployment because
Terraform sets `SCM_DO_BUILD_DURING_DEPLOYMENT=true`.

## 5. Verify

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<project_name>.azurewebsites.net/mcp
```

Expected: `401` or `405`. Either means the server is reachable and enforcing
the auth/method gate.

## 6. Connect Your MCP Client

Use:

```text
https://<project_name>.azurewebsites.net/mcp
```

If the client uses a redirect URI that is not in
`MCP_ALLOWED_REDIRECT_URIS`, add it to `allowed_redirect_uris` in Terraform,
apply again, and redeploy/restart the app.
