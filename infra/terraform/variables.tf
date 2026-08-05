variable "workload_name" {
  description = "Short workload name used in resource names."
  type        = string
  default     = "finops"
}

variable "environment_name" {
  description = "Deployment environment label."
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Azure region for resources."
  type        = string
  default     = "westus3"
}

variable "resource_group_name" {
  description = "Existing resource group where resources are deployed."
  type        = string
}

variable "finops_azure_cloud" {
  description = "Azure cloud technical value passed to the Function app."
  type        = string
  default     = "AzureCloud"

  validation {
    condition     = contains(["AzureCloud", "AzureUSGovernment"], var.finops_azure_cloud)
    error_message = "finops_azure_cloud must be AzureCloud or AzureUSGovernment."
  }
}

variable "finops_tenant_id" {
  description = "Tenant ID used by the FinOps ingestion runtime."
  type        = string
}

variable "finops_subscription_ids" {
  description = "Comma-separated subscription IDs to ingest."
  type        = string
}

variable "finops_timer_schedule" {
  description = "Timer trigger NCRONTAB schedule, UTC."
  type        = string
  default     = "0 0 6 * * *"
}

variable "sql_server_name" {
  description = "SQL logical server name. Must be globally unique."
  type        = string
}

variable "sql_database_name" {
  description = "SQL database name."
  type        = string
  default     = "FinOpsMaccRetail"
}

variable "sql_schema_name" {
  description = "SQL schema name used by the FinOps tables."
  type        = string
  default     = "finops"
}

variable "sql_sku_name" {
  description = "Azure SQL DB SKU name."
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "sql_max_size_gb" {
  description = "Azure SQL DB max size in GB."
  type        = number
  default     = 10
}

variable "sql_public_network_access_enabled" {
  description = "Enable public network access for SQL server. Use false when using private endpoint/network integration."
  type        = bool
  default     = true
}

variable "sql_allowed_client_ip" {
  description = "Optional client IP to allow through SQL firewall. Leave empty to skip firewall rule."
  type        = string
  default     = ""
}

variable "sql_entra_admin_login" {
  description = "Optional Microsoft Entra SQL admin display/login name."
  type        = string
  default     = ""
}

variable "sql_entra_admin_object_id" {
  description = "Optional Microsoft Entra SQL admin object ID."
  type        = string
  default     = ""
}

variable "function_plan_sku_name" {
  description = "Function App service plan SKU. Y1 is classic consumption."
  type        = string
  default     = "Y1"
}

variable "function_powershell_version" {
  description = "Function runtime PowerShell version."
  type        = string
  default     = "7.4"
}

variable "app_insights_retention_days" {
  description = "Application Insights retention in days."
  type        = number
  default     = 90
}
