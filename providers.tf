# Terraform runs as YOUR account (az login) to build everything. The
# application itself later signs in as the service principal created here.
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Use Entra ID (not storage account keys) for any storage data-plane calls.
  # Required because shared key access is disabled on the storage account.
  storage_use_azuread = true
}

provider "azuread" {}
