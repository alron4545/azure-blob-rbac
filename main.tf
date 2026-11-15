locals {
  suffix               = "uvu-${var.course}-${var.student_name}"
  storage_account_name = coalesce(var.storage_account_name, "stuvu${var.course}${var.student_name}")

  tags = {
    course     = var.course
    student    = var.student_name
    managed_by = "terraform"
  }
}

data "azuread_client_config" "current" {}

# =====================================================================
# Part 1: Resource group, storage account, private containers
# =====================================================================

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.suffix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "this" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Transport security
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # No anonymous/public blob access, ever
  allow_nested_items_to_be_public = false

  # Storage account keys (and SAS tokens signed with them) are disabled, so
  # every request must be authorized through Microsoft Entra ID + RBAC.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true

  cross_tenant_replication_enabled = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

# Container the application is allowed to use.
resource "azurerm_storage_container" "app" {
  name                  = var.app_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Second private container that is deliberately left OUTSIDE the
# application's role assignment scope (used for the negative test).
resource "azurerm_storage_container" "restricted" {
  name                  = var.restricted_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# =====================================================================
# Part 2: Application identity in Microsoft Entra ID
# =====================================================================

# The application registration: the global definition of the app.
resource "azuread_application" "reporting" {
  display_name     = "app-${local.suffix}-reporting"
  sign_in_audience = "AzureADMyOrg" # single tenant only
  owners           = [data.azuread_client_config.current.object_id]
}

# The service principal: the app's identity in THIS tenant. This is what
# signs in and what RBAC roles are assigned to.
resource "azuread_service_principal" "reporting" {
  client_id = azuread_application.reporting.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Short-lived client secret for the test client. Terraform replaces it every
# client_secret_rotation_days. The value is stored in Terraform state, which
# is why state files are git-ignored.
resource "time_rotating" "client_secret" {
  rotation_days = var.client_secret_rotation_days
}

resource "azuread_application_password" "reporting" {
  application_id = azuread_application.reporting.id
  display_name   = "terraform-managed-${var.client_secret_rotation_days}d"
  end_date       = time_rotating.client_secret.rotation_rfc3339

  rotate_when_changed = {
    rotation = time_rotating.client_secret.id
  }
}

# =====================================================================
# Part 4: Least-privilege RBAC on the app container only
# =====================================================================

resource "azurerm_role_assignment" "app_blob_access" {
  count = var.grant_blob_access ? 1 : 0

  # Scope = this one container, not the storage account, resource group,
  # or subscription. The restricted container is not covered.
  scope                = azurerm_storage_container.app.id
  role_definition_name = var.blob_role
  principal_id         = azuread_service_principal.reporting.object_id
  principal_type       = "ServicePrincipal"
  description          = "Reporting app: upload, list, and download blobs in ${var.app_container_name} only."
}
