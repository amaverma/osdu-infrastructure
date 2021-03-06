//  Copyright © Microsoft Corporation
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.


/*
.Synopsis
   Terraform Main Control
.DESCRIPTION
   This file holds the main control and resoures for bootstraping an OSDU Azure Devops Project.
*/

terraform {
  required_version = ">= 0.12"
  backend "azurerm" {
    key = "terraform.tfstate"
  }
}

#-------------------------------
# Providers
#-------------------------------
provider "azurerm" {
  version = "=2.26.0"
  features {}
}

provider "azuread" {
  version = "=1.0.0"
}

provider "random" {
  version = "~>2.2"
}

provider "external" {
  version = "~> 1.0"
}

provider "local" {
  version = "~> 1.4"
}

provider "null" {
  version = "~>2.1.0"
}





#-------------------------------
# Private Variables  (common.tf)
#-------------------------------
locals {
  // sanitize names
  prefix    = replace(trimspace(lower(var.prefix)), "_", "-")
  workspace = replace(trimspace(lower(terraform.workspace)), "-", "")
  suffix    = var.randomization_level > 0 ? "-${random_string.workspace_scope.result}" : ""

  // base prefix for resources, prefix constraints documented here: https://docs.microsoft.com/en-us/azure/architecture/best-practices/naming-conventions
  base_name    = length(local.prefix) > 0 ? "${local.prefix}-${local.workspace}${local.suffix}" : "${local.workspace}${local.suffix}"
  base_name_21 = length(local.base_name) < 22 ? local.base_name : "${substr(local.base_name, 0, 21 - length(local.suffix))}${local.suffix}"
  base_name_46 = length(local.base_name) < 47 ? local.base_name : "${substr(local.base_name, 0, 46 - length(local.suffix))}${local.suffix}"
  base_name_60 = length(local.base_name) < 61 ? local.base_name : "${substr(local.base_name, 0, 60 - length(local.suffix))}${local.suffix}"
  base_name_76 = length(local.base_name) < 77 ? local.base_name : "${substr(local.base_name, 0, 76 - length(local.suffix))}${local.suffix}"
  base_name_83 = length(local.base_name) < 84 ? local.base_name : "${substr(local.base_name, 0, 83 - length(local.suffix))}${local.suffix}"

  tenant_id           = data.azurerm_client_config.current.tenant_id
  resource_group_name = format("%s-%s-%s-rg", var.prefix, local.workspace, random_string.workspace_scope.result)
  retention_policy    = var.log_retention_days == 0 ? false : true

  // airflow.tf
  storage_name           = "${replace(local.base_name_21, "-", "")}config"
  storage_account_name   = "airflow-storage"
  storage_key_name       = "${local.storage_account_name}-key"
  redis_cache_name       = "${local.base_name}-cache"
  postgresql_name        = "${local.base_name}-pg"
  postgres_password      = coalesce(var.postgres_password, random_password.postgres[0].result)
  airflow_admin_password = coalesce(var.airflow_admin_password, random_password.airflow_admin_password[0].result)

  // network.tf
  vnet_name           = "${local.base_name_60}-vnet"
  fe_subnet_name      = "${local.base_name_21}-fe-subnet"
  aks_subnet_name     = "${local.base_name_21}-aks-subnet"
  be_subnet_name      = "${local.base_name_21}-be-subnet"
  app_gw_name         = "${local.base_name_60}-gw"
  appgw_identity_name = format("%s-agic-identity", local.app_gw_name)
  ssl_cert_name       = "appgw-ssl-cert"

  // cluster.tf
  aks_cluster_name  = "${local.base_name_21}-aks"
  aks_identity_name = format("%s-pod-identity", local.aks_cluster_name)
  aks_dns_prefix    = local.base_name_60
}


#-------------------------------
# Common Resources  (common.tf)
#-------------------------------
data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

data "terraform_remote_state" "central_resources" {
  backend = "azurerm"

  config = {
    storage_account_name = var.remote_state_account
    container_name       = var.remote_state_container
    key                  = format("terraform.tfstateenv:%s", var.central_resources_workspace_name)
  }
}

resource "random_string" "workspace_scope" {
  keepers = {
    # Generate a new id each time we switch to a new workspace or app id
    ws_name    = replace(trimspace(lower(terraform.workspace)), "_", "-")
    cluster_id = replace(trimspace(lower(var.prefix)), "_", "-")
  }

  length  = max(1, var.randomization_level) // error for zero-length
  special = false
  upper   = false
}


#-------------------------------
# Resource Group
#-------------------------------
resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.resource_group_location

  tags = var.resource_tags

  lifecycle {
    ignore_changes = [tags]
  }
}


#-------------------------------
# Storage
#-------------------------------
module "storage_account" {
  source = "../../../modules/providers/azure/storage-account"

  name                = local.storage_name
  resource_group_name = azurerm_resource_group.main.name
  container_names     = var.storage_containers
  share_names         = var.storage_shares
  queue_names         = var.storage_queues
  kind                = "StorageV2"
  replication_type    = "LRS"

  resource_tags = var.resource_tags
}

// Add the Storage Account Name to the Vault
resource "azurerm_key_vault_secret" "storage_name" {
  name         = local.storage_account_name
  value        = module.storage_account.name
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}

// Add the Storage Key to the Vault
resource "azurerm_key_vault_secret" "storage_key" {
  name         = local.storage_key_name
  value        = module.storage_account.primary_access_key
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}


#-------------------------------
# PostgreSQL (main.tf)
#-------------------------------
resource "random_password" "postgres" {
  count = var.postgres_password == "" ? 1 : 0

  length           = 8
  special          = true
  override_special = "_%@"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

module "postgreSQL" {
  source = "../../../modules/providers/azure/postgreSQL"

  resource_group_name       = azurerm_resource_group.main.name
  name                      = local.postgresql_name
  databases                 = var.postgres_databases
  admin_user                = var.postgres_username
  admin_password            = local.postgres_password
  sku                       = var.postgres_sku
  postgresql_configurations = var.postgres_configurations

  storage_mb                   = 5120
  server_version               = "10.0"
  backup_retention_days        = 7
  geo_redundant_backup_enabled = true
  auto_grow_enabled            = true
  ssl_enforcement_enabled      = true

  resource_tags = var.resource_tags
}

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-password"
  value        = local.postgres_password
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}

// Diagnostics Setup
resource "azurerm_monitor_diagnostic_setting" "postgres_diagnostics" {
  name                       = "postgres_diagnostics"
  target_resource_id         = module.postgreSQL.server_id
  log_analytics_workspace_id = data.terraform_remote_state.central_resources.outputs.log_analytics_id

  log {
    category = "PostgreSQLLogs"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "QueryStoreRuntimeStatistics"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "QueryStoreWaitStatistics"

    retention_policy {
      enabled = false
    }
  }


  metric {
    category = "AllMetrics"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }
}


#-------------------------------
# Azure Redis Cache (main.tf)
#-------------------------------

module "redis_cache" {
  source = "../../../modules/providers/azure/redis-cache"

  name                = local.redis_cache_name
  resource_group_name = azurerm_resource_group.main.name
  capacity            = var.redis_capacity

  memory_features     = var.redis_config_memory
  premium_tier_config = var.redis_config_schedule

  resource_tags = var.resource_tags
}

resource "azurerm_key_vault_secret" "redis_password" {
  name         = "redis-password"
  value        = module.redis_cache.primary_access_key
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}

// Diagnostics Setup
resource "azurerm_monitor_diagnostic_setting" "redis_diagnostics" {
  name                       = "redis_diagnostics"
  target_resource_id         = module.redis_cache.id
  log_analytics_workspace_id = data.terraform_remote_state.central_resources.outputs.log_analytics_id


  metric {
    category = "AllMetrics"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }
}


#-------------------------------
# Airflow (main.tf)
#-------------------------------

resource "random_password" "airflow_admin_password" {
  count = var.airflow_admin_password == "" ? 1 : 0

  length           = 8
  special          = true
  override_special = "_%@"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_string" "airflow_fernete_key_rnd" {
  keepers = {
    postgresql_name = local.postgresql_name
  }
  length      = 32
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
}

resource "azurerm_key_vault_secret" "airflow_fernet_key_secret" {
  name         = "airflow-fernet-key"
  value        = base64encode(random_string.airflow_fernete_key_rnd.result)
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}

resource "azurerm_key_vault_secret" "airflow_admin_password" {
  name         = "airflow-admin-password"
  value        = local.airflow_admin_password
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id
}


#-------------------------------
# Network (main.tf)
#-------------------------------
module "network" {
  source = "../../../modules/providers/azure/network"

  name                = local.vnet_name
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.address_space
  subnet_prefixes     = [var.subnet_fe_prefix, var.subnet_aks_prefix, var.subnet_be_prefix]
  subnet_names        = [local.fe_subnet_name, local.aks_subnet_name, local.be_subnet_name]

  resource_tags = var.resource_tags
}

// Diagnostics Setup
resource "azurerm_monitor_diagnostic_setting" "vnet_diagnostics" {
  name                       = "vnet_diagnostics"
  target_resource_id         = module.network.id
  log_analytics_workspace_id = data.terraform_remote_state.central_resources.outputs.log_analytics_id

  log {
    category = "VMProtectionAlerts"
    enabled  = false

    retention_policy {
      days    = 0
      enabled = false
    }
  }


  metric {
    category = "AllMetrics"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }
}

# Create a Default SSL Certificate.
resource "azurerm_key_vault_certificate" "default" {
  count = var.ssl_certificate_file == "" ? 1 : 0

  name         = local.ssl_cert_name
  key_vault_id = data.terraform_remote_state.central_resources.outputs.keyvault_id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      # Server Authentication = 1.3.6.1.5.5.7.3.1
      # Client Authentication = 1.3.6.1.5.5.7.3.2
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]

      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyAgreement",
        "keyCertSign",
        "keyEncipherment",
      ]

      subject_alternative_names {
        dns_names = [var.dns_name, "${local.base_name}-gw.${azurerm_resource_group.main.location}.cloudapp.azure.com"]
      }

      subject            = "CN=*.contoso.com"
      validity_in_months = 12
    }
  }
}

module "appgateway" {
  source = "../../../modules/providers/azure/aks-appgw"

  name                = local.app_gw_name
  resource_group_name = azurerm_resource_group.main.name

  vnet_name            = module.network.name
  vnet_subnet_id       = module.network.subnets.0
  keyvault_id          = data.terraform_remote_state.central_resources.outputs.keyvault_id
  keyvault_secret_id   = azurerm_key_vault_certificate.default.0.secret_id
  ssl_certificate_name = local.ssl_cert_name

  resource_tags = var.resource_tags
}

// Identity for AGIC
resource "azurerm_user_assigned_identity" "agicidentity" {
  name                = local.appgw_identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

// Managed Identity Operator role for AKS to AGIC Identity
resource "azurerm_role_assignment" "mi_ag_operator" {
  principal_id         = module.aks.kubelet_object_id
  scope                = azurerm_user_assigned_identity.agicidentity.id
  role_definition_name = "Managed Identity Operator"
}

// Contributor Role for AGIC to the AppGateway
resource "azurerm_role_assignment" "appgwcontributor" {
  principal_id         = azurerm_user_assigned_identity.agicidentity.principal_id
  scope                = module.appgateway.id
  role_definition_name = "Contributor"
}

// Reader Role for AGIC to the Resource Group
resource "azurerm_role_assignment" "agic_resourcegroup_reader" {
  principal_id         = azurerm_user_assigned_identity.agicidentity.principal_id
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Reader"
}

// Managed Identity Operator Role for AGIC to AppGateway Managed Identity
resource "azurerm_role_assignment" "agic_app_gw_mi" {
  principal_id         = azurerm_user_assigned_identity.agicidentity.principal_id
  scope                = module.appgateway.managed_identity_resource_id
  role_definition_name = "Managed Identity Operator"
}

// Diagnostics Setup
resource "azurerm_monitor_diagnostic_setting" "gw_diagnostics" {
  name                       = "gw_diagnostics"
  target_resource_id         = module.appgateway.id
  log_analytics_workspace_id = data.terraform_remote_state.central_resources.outputs.log_analytics_id


  log {
    category = "ApplicationGatewayAccessLog"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "ApplicationGatewayPerformanceLog"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "ApplicationGatewayFirewallLog"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }
}

#-------------------------------
# Azure AKS  (cluster.tf)
#-------------------------------
module "aks" {
  source = "../../../modules/providers/azure/aks"

  name                = local.aks_cluster_name
  resource_group_name = azurerm_resource_group.main.name

  dns_prefix         = local.aks_dns_prefix
  agent_vm_count     = var.aks_agent_vm_count
  agent_vm_size      = var.aks_agent_vm_size
  vnet_subnet_id     = module.network.subnets.1
  ssh_public_key     = file(var.ssh_public_key_file)
  kubernetes_version = var.kubernetes_version
  log_analytics_id   = data.terraform_remote_state.central_resources.outputs.log_analytics_id

  msi_enabled               = true
  oms_agent_enabled         = true
  auto_scaling_default_node = true
  kubeconfig_to_disk        = false
  enable_kube_dashboard     = false

  resource_tags = var.resource_tags
}

data "azurerm_resource_group" "aks_node_resource_group" {
  name = module.aks.node_resource_group
}

// Identity for Pod Identity
resource "azurerm_user_assigned_identity" "podidentity" {
  name                = local.aks_identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

// Managed Identity Operator role for AKS to Node Resource Group
resource "azurerm_role_assignment" "all_mi_operator" {
  principal_id         = module.aks.kubelet_object_id
  scope                = data.azurerm_resource_group.aks_node_resource_group.id
  role_definition_name = "Managed Identity Operator"
}

// Virtual Machine Contributor role for AKS to Node Resource Group
resource "azurerm_role_assignment" "vm_contributor" {
  principal_id         = module.aks.kubelet_object_id
  scope                = data.azurerm_resource_group.aks_node_resource_group.id
  role_definition_name = "Virtual Machine Contributor"
}

// Azure Container Registry Reader role for AKS to ACR
resource "azurerm_role_assignment" "acr_reader" {
  principal_id         = module.aks.kubelet_object_id
  scope                = data.terraform_remote_state.central_resources.outputs.container_registry_id
  role_definition_name = "AcrPull"
}

// Managed Identity Operator role for AKS to Pod Identity
resource "azurerm_role_assignment" "mi_operator" {
  principal_id         = module.aks.kubelet_object_id
  scope                = azurerm_user_assigned_identity.podidentity.id
  role_definition_name = "Managed Identity Operator"
}

// Managed Identity Operator role for AKS to the OSDU Identity
resource "azurerm_role_assignment" "osdu_identity_mi_operator" {
  principal_id         = module.aks.kubelet_object_id
  scope                = data.terraform_remote_state.central_resources.outputs.osdu_identity_id
  role_definition_name = "Managed Identity Operator"
}

// Diagnostics Setup
resource "azurerm_monitor_diagnostic_setting" "aks_diagnostics" {
  name                       = "aks_diagnostics"
  target_resource_id         = module.aks.id
  log_analytics_workspace_id = data.terraform_remote_state.central_resources.outputs.log_analytics_id

  log {
    category = "cluster-autoscaler"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "guard"
    enabled  = false

    retention_policy {
      days    = 0
      enabled = false
    }
  }

  log {
    category = "kube-apiserver"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "kube-audit"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "kube-audit-admin"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "kube-controller-manager"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  log {
    category = "kube-scheduler"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      days    = var.log_retention_days
      enabled = local.retention_policy
    }
  }
}


#-------------------------------
# Providers  (common.tf)
#-------------------------------

// Hook-up kubectl Provider for Terraform
provider "kubernetes" {
  version                = "~> 1.11.3"
  load_config_file       = false
  host                   = module.aks.kube_config_block.0.host
  username               = module.aks.kube_config_block.0.username
  password               = module.aks.kube_config_block.0.password
  client_certificate     = base64decode(module.aks.kube_config_block.0.client_certificate)
  client_key             = base64decode(module.aks.kube_config_block.0.client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config_block.0.cluster_ca_certificate)
}

// Hook-up helm Provider for Terraform
provider "helm" {
  version = "~> 1.2.3"

  kubernetes {
    load_config_file       = false
    host                   = module.aks.kube_config_block.0.host
    username               = module.aks.kube_config_block.0.username
    password               = module.aks.kube_config_block.0.password
    client_certificate     = base64decode(module.aks.kube_config_block.0.client_certificate)
    client_key             = base64decode(module.aks.kube_config_block.0.client_key)
    cluster_ca_certificate = base64decode(module.aks.kube_config_block.0.cluster_ca_certificate)
  }
}