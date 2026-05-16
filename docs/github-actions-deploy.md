# Optional GitHub Actions Deploy

This public repo does not include a live deploy workflow. That is deliberate:
each deployment belongs to the adopter's Azure subscription, Entra tenant, and
GitHub repository.

If you want push-button deploys from your own fork or copy, enable the optional
Terraform resources and add this workflow in your repository.

## 1. Enable the Terraform OIDC resources

In `infra/terraform.tfvars`:

```hcl
enable_github_actions_deploy = true
github_repo                  = "your-handle/your-repo"
```

Then run:

```bash
terraform apply
terraform output github_actions_secrets
```

Add the output values as repository secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

If you changed `project_name` from `pbi-mcp`, also add repository variables:

- `AZURE_APP_NAME`
- `AZURE_RESOURCE_GROUP`

## 2. Add the workflow

Create `.github/workflows/deploy.yml` in your own repository:

```yaml
name: Build and Deploy

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      APP_NAME: ${{ vars.AZURE_APP_NAME || 'pbi-mcp' }}
      RESOURCE_GROUP: ${{ vars.AZURE_RESOURCE_GROUP || 'pbi-mcp-rg' }}

    steps:
      - uses: actions/checkout@v4

      - name: Build deployment artifact
        run: |
          zip -r app.zip pbi_mcp_remote.py requirements.txt

      - name: Login to Azure (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy to App Service
        run: |
          az webapp deploy \
            --name "$APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --src-path app.zip \
            --type zip

      - name: Smoke test
        run: |
          url="https://${APP_NAME}.azurewebsites.net/mcp"
          for i in $(seq 1 12); do
            status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
            if [ "$status" = "401" ] || [ "$status" = "405" ]; then
              echo "Server is up (HTTP $status)"
              exit 0
            fi
            echo "Attempt $i/12: HTTP $status; waiting 15s..."
            sleep 15
          done
          exit 1
```
