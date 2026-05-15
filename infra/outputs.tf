output "app_service_url" {
  description = "Public URL of the deployed MCP server"
  value       = "https://${azurerm_linux_web_app.main.default_hostname}"
}

output "mcp_endpoint" {
  description = "MCP endpoint URL — paste into your MCP client's custom connector config"
  value       = "https://${azurerm_linux_web_app.main.default_hostname}/mcp"
}

output "mcp_app_client_id" {
  description = "Client ID of the MCP server app registration (also exposed to App Service as PBI_CLIENT_ID)"
  value       = azuread_application.mcp_server.client_id
}

output "mcp_app_display_name" {
  description = "Display name of the app registration — find it in Portal > Entra ID > App registrations to grant admin consent"
  value       = azuread_application.mcp_server.display_name
}

output "github_actions_secrets" {
  description = "Add these three values as repo secrets in Settings > Secrets and variables > Actions"
  value = {
    AZURE_CLIENT_ID       = azuread_application.deploy.client_id
    AZURE_TENANT_ID       = var.tenant_id
    AZURE_SUBSCRIPTION_ID = var.subscription_id
  }
}

output "next_steps" {
  description = "Things you still have to do manually after terraform apply succeeds"
  value       = <<-EOT
    1. Grant admin consent: Portal > Entra ID > App registrations > ${azuread_application.mcp_server.display_name} > API permissions > Grant admin consent.
    2. Add the three github_actions_secrets above as GitHub repo secrets.
    3. (Strongly recommended) Configure Conditional Access scoped to the new app. See docs/azure-setup.md.
    4. Run the Build and Deploy GitHub Actions workflow — it will publish to ${azurerm_linux_web_app.main.default_hostname}.
    5. Connect from your MCP client at https://${azurerm_linux_web_app.main.default_hostname}/mcp
  EOT
}
