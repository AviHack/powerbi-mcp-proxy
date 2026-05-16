# Single-module Terraform for powerbi-mcp-proxy.
#
# Provisions everything needed to run the MCP server on Azure App Service:
#   - Resource group + Key Vault (with secrets)
#   - Entra app registration (single-tenant, with Power BI Dataset.Read.All)
#   - Linux Web App + managed identity wired to Key Vault
#   - Optional GitHub Actions OIDC federation (repo scope)
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars   # edit the placeholders
#   terraform init
#   terraform plan        # review every resource that will be created
#   terraform apply
#
# After apply: in the Azure Portal, grant admin consent for Dataset.Read.All
# on the new app registration. See docs/azure-setup.md.

data "azurerm_client_config" "current" {}

# Power BI Service well-known IDs (Microsoft constants — not tenant-specific)
locals {
  power_bi_api_id     = "00000009-0000-0000-c000-000000000000"
  dataset_read_all_id = "7f33e027-4039-419b-938e-2f8ca153e68e"
  app_service_url     = "https://${var.project_name}.azurewebsites.net"
}

# ---------------------------------------------------------------------------
# Foundation: resource group + Key Vault
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_key_vault" "main" {
  name                     = "${var.project_name}-kv"
  location                 = azurerm_resource_group.main.location
  resource_group_name      = azurerm_resource_group.main.name
  tenant_id                = var.tenant_id
  sku_name                 = "standard"
  purge_protection_enabled = true

  tags = local.tags
}

# Allow whoever runs terraform to manage secrets during apply.
# Kept as a separate resource (not an inline access_policy block) so it doesn't
# conflict with the webapp access policy below — mixing inline and separate
# azurerm_key_vault_access_policy resources on the same vault causes plan drift.
resource "azurerm_key_vault_access_policy" "terraform_runner" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "Set", "Delete", "List"]
}

# ---------------------------------------------------------------------------
# Identity: app registration + secrets
# ---------------------------------------------------------------------------

resource "azuread_application" "mcp_server" {
  display_name     = "${var.project_name}-server"
  sign_in_audience = "AzureADMyOrg" # single-tenant — see SECURITY.md before changing

  web {
    redirect_uris = [
      "${local.app_service_url}/auth/callback",
    ]
  }

  api {
    requested_access_token_version = 2

    oauth2_permission_scope {
      admin_consent_description  = "Access the Power BI MCP server tools"
      admin_consent_display_name = "Access Power BI MCP tools"
      id                         = random_uuid.mcp_access_scope.result
      enabled                    = true
      type                       = "User"
      value                      = "MCP.Access"
    }
  }

  required_resource_access {
    resource_app_id = local.power_bi_api_id

    resource_access {
      id   = local.dataset_read_all_id
      type = "Scope"
    }
  }
}

resource "random_uuid" "mcp_access_scope" {}

resource "azuread_service_principal" "mcp_server" {
  client_id = azuread_application.mcp_server.client_id
}

resource "azuread_application_password" "mcp_server" {
  application_id = azuread_application.mcp_server.id
  display_name   = "mcp-server-secret"
  end_date       = timeadd(timestamp(), "8760h") # 1 year — rotate annually

  lifecycle {
    # Avoid recreating the secret on every apply (timestamp() drifts)
    ignore_changes = [end_date]
  }
}

resource "random_password" "jwt_signing_key" {
  length  = 64
  special = false
}

resource "azurerm_key_vault_secret" "client_secret" {
  name         = "PBI-CLIENT-SECRET"
  value        = azuread_application_password.mcp_server.value
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "jwt_signing_key" {
  name         = "JWT-SIGNING-KEY"
  value        = random_password.jwt_signing_key.result
  key_vault_id = azurerm_key_vault.main.id
}

# ---------------------------------------------------------------------------
# Compute: App Service + Web App
# ---------------------------------------------------------------------------

resource "azurerm_service_plan" "main" {
  name                = "${var.project_name}-plan"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "main" {
  name                = var.project_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
    app_command_line = "gunicorn -k uvicorn.workers.UvicornWorker --bind=0.0.0.0:8000 pbi_mcp_remote:app"
  }

  app_settings = {
    "PBI_CLIENT_ID"                  = azuread_application.mcp_server.client_id
    "PBI_TENANT_ID"                  = var.tenant_id
    "PBI_CLIENT_SECRET"              = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.main.name};SecretName=PBI-CLIENT-SECRET)"
    "JWT_SIGNING_KEY"                = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.main.name};SecretName=JWT-SIGNING-KEY)"
    "MCP_SERVER_URL"                 = local.app_service_url
    "MCP_ALLOWED_REDIRECT_URIS"      = var.allowed_redirect_uris
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
  }

  identity {
    type = "SystemAssigned"
  }

  https_only = true

  tags = local.tags
}

# Allow the Web App's managed identity to read secrets from Key Vault
resource "azurerm_key_vault_access_policy" "webapp" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = azurerm_linux_web_app.main.identity[0].principal_id

  secret_permissions = ["Get"]
}

# ---------------------------------------------------------------------------
# Optional CI/CD: GitHub Actions OIDC + scoped Contributor role
# ---------------------------------------------------------------------------

resource "azuread_application" "deploy" {
  count        = var.enable_github_actions_deploy ? 1 : 0
  display_name = "${var.project_name}-deploy"

  lifecycle {
    precondition {
      condition     = var.github_repo != null
      error_message = "github_repo is required when enable_github_actions_deploy is true."
    }
  }
}

resource "azuread_service_principal" "deploy" {
  count     = var.enable_github_actions_deploy ? 1 : 0
  client_id = azuread_application.deploy[0].client_id
}

# Trust GitHub Actions running on the main branch of var.github_repo only
resource "azuread_application_federated_identity_credential" "github_main" {
  count          = var.enable_github_actions_deploy ? 1 : 0
  application_id = azuread_application.deploy[0].id
  display_name   = "github-actions-main"
  description    = "GitHub Actions deployment from main branch only"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repo}:ref:refs/heads/main"
}

# Contributor on the resource group only — needed because zip-deploy /
# az webapp up calls serverfarms/write, which Website Contributor lacks.
resource "azurerm_role_assignment" "deploy_contributor" {
  count                = var.enable_github_actions_deploy ? 1 : 0
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deploy[0].object_id
}
