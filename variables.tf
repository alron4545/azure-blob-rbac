variable "subscription_id" {
  description = "Azure subscription to deploy into (az account show --query id -o tsv)."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westus2"
}

# ---------- Naming: [resource]-uvu-[course]-[studentname] ----------

variable "course" {
  description = "Course identifier used in resource names."
  type        = string
  default     = "it3200"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.course))
    error_message = "course must be lowercase letters and numbers only."
  }
}

variable "student_name" {
  description = "Student identifier used in resource names."
  type        = string
  default     = "michael"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.student_name))
    error_message = "student_name must be lowercase letters and numbers only."
  }
}

variable "storage_account_name" {
  description = "Override the storage account name. Must be globally unique, 3-24 lowercase letters and numbers. Leave null to use st + uvu + course + student_name (e.g. stuvuit3200michael)."
  type        = string
  default     = null

  validation {
    condition     = var.storage_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase letters and numbers."
  }
}

# ---------- Storage ----------

variable "app_container_name" {
  description = "Container the application is allowed to use."
  type        = string
  default     = "reports"
}

variable "restricted_container_name" {
  description = "Second private container the application must NOT be able to access (negative test)."
  type        = string
  default     = "restricted"
}

# ---------- Identity and access ----------

variable "grant_blob_access" {
  description = "Create the RBAC role assignment that lets the service principal use the app container. Set to false to test access before permissions (Part 3) or to remove access (bonus)."
  type        = bool
  default     = true
}

variable "blob_role" {
  description = "Built-in data-plane role given to the service principal on the app container."
  type        = string
  default     = "Storage Blob Data Contributor"

  validation {
    condition = contains([
      "Storage Blob Data Reader",
      "Storage Blob Data Contributor",
    ], var.blob_role)
    error_message = "Only data-plane blob roles below Owner are allowed (Storage Blob Data Reader or Contributor)."
  }
}

variable "client_secret_rotation_days" {
  description = "How long the service principal's client secret is valid before Terraform replaces it."
  type        = number
  default     = 30

  validation {
    condition     = var.client_secret_rotation_days >= 1 && var.client_secret_rotation_days <= 90
    error_message = "Keep client secrets short-lived: 1 to 90 days."
  }
}
