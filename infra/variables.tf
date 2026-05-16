variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant GUID (must be a specific tenant — not 'common'/'organizations')"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "environment" {
  description = "Environment tag (poc, staging, production)"
  type        = string
  default     = "production"
}

variable "owner" {
  description = "Owner tag for resource tracking"
  type        = string
}

variable "project_name" {
  description = "Used in resource naming (App Service, Key Vault, etc.). Must be globally unique for App Service. Lowercase letters, numbers, hyphens; 1-21 chars so the derived '<name>-kv' Key Vault name stays valid."
  type        = string
  default     = "pbi-mcp"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,19}[a-z0-9])?$", var.project_name)) && !can(regex("--", var.project_name))
    error_message = "project_name must be 1-21 chars, lowercase letters/numbers/hyphens, start and end with a letter or number, and not contain consecutive hyphens."
  }
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format for optional OIDC deployment. Required only when enable_github_actions_deploy is true."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.github_repo == null || can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be null or in owner/repo format, e.g. 'AviHack/powerbi-mcp-proxy'."
  }
}

variable "enable_github_actions_deploy" {
  description = "Create a GitHub Actions OIDC deploy identity for the repository in github_repo."
  type        = bool
  default     = false
}

variable "app_service_sku" {
  description = "App Service Plan SKU. B1 (~$13/mo) is the cheapest viable. F1 (free) cannot use Key Vault refs."
  type        = string
  default     = "B1"
}

variable "allowed_redirect_uris" {
  description = "Comma-separated MCP client redirect URIs allowed via DCR. Path wildcards OK; never use a bare '*'. Defaults to Claude.ai. Add ChatGPT, Copilot CLI etc. as you verify them."
  type        = string
  default     = "https://claude.ai/api/mcp/*"
}

locals {
  tags = {
    project     = var.project_name
    environment = var.environment
    owner       = var.owner
    purpose     = "Self-hosted Power BI MCP server"
    managed_by  = "terraform"
  }
  resource_group_name = "${var.project_name}-rg"
}
