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
      # Allow `terraform destroy` to fully purge the soft-deleted vault so
      # adopters can rebuild with the same name. If you want extended retention,
      # set this to false and accept that destroy will leave tombstones.
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}
