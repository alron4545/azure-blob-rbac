# Offline checks with mocked providers: no Azure credentials or cloud calls.
# Run with: terraform test

mock_provider "azurerm" {}
mock_provider "time" {}

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
}

override_resource {
  target = azurerm_storage_account.this
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-uvu-it3200-michael/providers/Microsoft.Storage/storageAccounts/stuvuit3200michael" }
}

override_resource {
  target = azuread_application.reporting
  values = {
    id        = "/applications/22222222-2222-2222-2222-222222222222"
    object_id = "22222222-2222-2222-2222-222222222222"
    client_id = "33333333-3333-3333-3333-333333333333"
  }
}

override_resource {
  target = time_rotating.client_secret
  values = { rotation_rfc3339 = "2026-12-14T00:00:00Z" }
}

override_resource {
  target = azurerm_storage_container.app
  values = { id = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st/blobServices/default/containers/reports" }
}

override_resource {
  target = azurerm_storage_container.restricted
  values = { id = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st/blobServices/default/containers/restricted" }
}

override_resource {
  target = azuread_service_principal.reporting
  values = { object_id = "11111111-1111-1111-1111-111111111111" }
}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "names_follow_the_convention" {
  command = apply

  assert {
    condition     = azurerm_resource_group.this.name == "rg-uvu-it3200-michael"
    error_message = "Resource group must be rg-uvu-it3200-michael."
  }

  assert {
    condition     = azurerm_storage_account.this.name == "stuvuit3200michael"
    error_message = "Storage account must default to stuvuit3200michael."
  }

  assert {
    condition     = azuread_application.reporting.display_name == "app-uvu-it3200-michael-reporting"
    error_message = "Application name must follow the convention."
  }
}

run "storage_is_private_and_keyless" {
  command = apply

  assert {
    condition = (
      azurerm_storage_account.this.https_traffic_only_enabled &&
      azurerm_storage_account.this.min_tls_version == "TLS1_2"
    )
    error_message = "Storage must require HTTPS and TLS 1.2."
  }

  assert {
    condition     = azurerm_storage_account.this.allow_nested_items_to_be_public == false
    error_message = "Anonymous public blob access must be disabled."
  }

  assert {
    condition     = azurerm_storage_account.this.shared_access_key_enabled == false
    error_message = "Storage account keys must be disabled."
  }

  assert {
    condition = (
      azurerm_storage_container.app.container_access_type == "private" &&
      azurerm_storage_container.restricted.container_access_type == "private"
    )
    error_message = "Both containers must be private."
  }
}

run "least_privilege_role_on_one_container" {
  command = apply

  assert {
    condition     = length(azurerm_role_assignment.app_blob_access) == 1
    error_message = "Exactly one role assignment expected."
  }

  assert {
    condition     = azurerm_role_assignment.app_blob_access[0].role_definition_name == "Storage Blob Data Contributor"
    error_message = "Role must be Storage Blob Data Contributor."
  }

  assert {
    condition     = azurerm_role_assignment.app_blob_access[0].scope == azurerm_storage_container.app.id
    error_message = "Role must be scoped to the app container only."
  }

  assert {
    condition     = azurerm_role_assignment.app_blob_access[0].scope != azurerm_storage_container.restricted.id
    error_message = "The restricted container must not be in scope."
  }

  assert {
    condition = (
      azurerm_role_assignment.app_blob_access[0].principal_id == azuread_service_principal.reporting.object_id &&
      azurerm_role_assignment.app_blob_access[0].principal_type == "ServicePrincipal"
    )
    error_message = "Role must be assigned to the service principal."
  }
}

run "access_can_be_turned_off" {
  command = apply

  variables {
    grant_blob_access = false
  }

  assert {
    condition     = length(azurerm_role_assignment.app_blob_access) == 0
    error_message = "No role assignment should exist when grant_blob_access = false."
  }

  assert {
    condition     = output.role_assignment == null
    error_message = "role_assignment output should be null without access."
  }
}

run "rejects_owner_role" {
  command = plan

  variables {
    blob_role = "Owner"
  }

  expect_failures = [var.blob_role]
}

run "rejects_long_lived_secret" {
  command = plan

  variables {
    client_secret_rotation_days = 365
  }

  expect_failures = [var.client_secret_rotation_days]
}
