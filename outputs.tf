output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "blob_endpoint" {
  value = azurerm_storage_account.this.primary_blob_endpoint
}

output "app_container_name" {
  value = azurerm_storage_container.app.name
}

output "restricted_container_name" {
  value = azurerm_storage_container.restricted.name
}

# Identity details. These IDs are identifiers, not secrets, but still redact
# them in screenshots when practical.
output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "client_id" {
  description = "Application (client) ID: used to sign in as the service principal."
  value       = azuread_application.reporting.client_id
}

output "application_object_id" {
  description = "Object ID of the application registration."
  value       = azuread_application.reporting.object_id
}

output "service_principal_object_id" {
  description = "Object ID of the service principal (what RBAC is assigned to)."
  value       = azuread_service_principal.reporting.object_id
}

output "client_secret_expires" {
  value = azuread_application_password.reporting.end_date
}

output "role_assignment" {
  description = "The RBAC role, scope, and principal, or null when grant_blob_access = false."
  value = var.grant_blob_access ? {
    role         = azurerm_role_assignment.app_blob_access[0].role_definition_name
    scope        = azurerm_role_assignment.app_blob_access[0].scope
    principal_id = azurerm_role_assignment.app_blob_access[0].principal_id
  } : null
}

# Sensitive: hidden in normal output. Read it only into an environment
# variable (see scripts/test-access.sh); never paste it anywhere.
output "client_secret" {
  value     = azuread_application_password.reporting.value
  sensitive = true
}
