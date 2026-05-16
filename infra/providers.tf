terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Strongly recommended: configure a remote backend BEFORE first apply so
  # secrets (client_secret, JWT_SIGNING_KEY) never land in local tfstate.
  # See docs/troubleshooting.md > "Setting up remote tfstate".
  #
  # backend "azurerm" {
  #   resource_group_name  = "<your-tfstate-resource-group>"
  #   storage_account_name = "<your-tfstate-storage-account>"
  #   container_name       = "tfstate"
  #   key                  = "terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      # This only applies when purge protection is disabled. The template enables
      # purge protection on the vault, so production destroys intentionally leave
      # the vault name unreusable until Azure's retention period expires.
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}
