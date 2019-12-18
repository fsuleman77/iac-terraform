/*
.Synopsis
   Terraform Main Control
.DESCRIPTION
   This file holds the main control and resoures for the iac-terraform web-data application.
*/

terraform {
  required_version = ">= 0.12"
  backend "azurerm" {
    key = "terraform.tfstate"
  }
}

#-------------------------------
# Application Variables  (variables.tf)
#-------------------------------
variable "name" {
  description = "An identifier used to construct the names of all resources in this template."
  type        = string
}

variable "location" {
  description = "The Azure region where all resources in this template should be created."
  type        = string
}

variable "randomization_level" {
  description = "Number of additional random characters to include in resource names to insulate against unexpected resource name collisions."
  type        = number
  default     = 8
}

variable "deployment_targets" {
  description = "Metadata about apps to deploy, such as image metadata."
  type = list(object({
    app_name                 = string
    image_name               = string
    image_release_tag_prefix = string
  }))
}

variable "docker_registry_server_url" {
  description = "The url of the container registry that will be utilized to pull container into the Web Apps for containers"
  type        = string
  default     = "docker.io"
}

variable "cosmosdb_container_name" {
  description = "The cosmosdb container name."
  type        = string
  default     = "example"
}


#-------------------------------
# Private Variables  (common.tf)
#-------------------------------
locals {
  // Sanitized Names
  app_id    = random_string.workspace_scope.keepers.app_id
  location  = replace(trimspace(lower(var.location)), "_", "-")
  ws_name   = random_string.workspace_scope.keepers.ws_name
  suffix    = var.randomization_level > 0 ? "-${random_string.workspace_scope.result}" : ""

  // base name for resources, name constraints documented here: https://docs.microsoft.com/en-us/azure/architecture/best-practices/naming-conventions
  base_name    = length(local.app_id) > 0 ? "${local.ws_name}${local.suffix}-${local.app_id}" : "${local.ws_name}${local.suffix}"
  base_name_21 = length(local.base_name) < 22 ? local.base_name : "${substr(local.base_name, 0, 21 - length(local.suffix))}${local.suffix}"
  base_name_46 = length(local.base_name) < 47 ? local.base_name : "${substr(local.base_name, 0, 46 - length(local.suffix))}${local.suffix}"
  base_name_60 = length(local.base_name) < 61 ? local.base_name : "${substr(local.base_name, 0, 60 - length(local.suffix))}${local.suffix}"
  base_name_76 = length(local.base_name) < 77 ? local.base_name : "${substr(local.base_name, 0, 76 - length(local.suffix))}${local.suffix}"
  base_name_83 = length(local.base_name) < 84 ? local.base_name : "${substr(local.base_name, 0, 83 - length(local.suffix))}${local.suffix}"

  // Resolved resource names
  name                  = "${local.base_name_83}"
  keyvault_name         = "${local.base_name_21}-kv"
  cosmosdb_account_name = "${local.base_name_83}-db"
  cosmosdb_database_name = "${local.base_name_83}"
  service_plan_name     = "${local.base_name_83}-plan"
  app_service_name      = "${local.base_name_83}"

  // Resolved TF Vars
  reg_url = var.docker_registry_server_url
  app_services = {
    for target in var.deployment_targets :
    target.app_name => {
      image = "${target.image_name}:${target.image_release_tag_prefix}"
    }
  }
}


#-------------------------------
# Application Resources  (common.tf)
#-------------------------------
resource "random_string" "workspace_scope" {
  keepers = {
    # Generate a new id each time we switch to a new workspace or app id
    ws_name = replace(trimspace(lower(terraform.workspace)), "_", "-")
    app_id  = replace(trimspace(lower(var.name)), "_", "-")
  }

  length  = max(1, var.randomization_level) // error for zero-length
  special = false
  upper   = false
}


#-------------------------------
# Azure Required Providers
#-------------------------------
module "provider" {
  source = "../../modules/provider"
}


#-------------------------------
# Resource Group
#-------------------------------
module "resource_group" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/resource-group"

  # Module variable
  name     = local.name
  location = local.location

  resource_tags          = {
    environment = local.ws_name
  } 
}


#-------------------------------
# Azure Key Vault
#-------------------------------
module "keyvault" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/keyvault"

  # Module variable
  name           = local.keyvault_name
  resource_group_name = module.resource_group.name

  resource_tags          = {
    environment = local.ws_name
  }
}


#-------------------------------
# Cosmos Database
#-------------------------------
module "cosmosdb" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/cosmosdb"

  # Module variable
  name                     = local.cosmosdb_account_name
  resource_group_name      = module.resource_group.name
  kind                     = "GlobalDocumentDB"
  automatic_failover       = false
  consistency_level        = "Session"
  primary_replica_location = local.location
  database_name            = local.cosmosdb_database_name
  container_name           = var.cosmosdb_container_name

  resource_tags          = {
    environment = local.ws_name
  }
}

#-------------------------------
# Azure Key Vault Secret
#-------------------------------
module "keyvault-secret" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/keyvault-secret"

  # Module variable
  keyvault_id          = module.keyvault.id
  secrets              = {
    "cosmosdb-key" = module.cosmosdb.primary_master_key
  }
}

#-------------------------------
# Web Site
#-------------------------------
module "service_plan" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/service-plan"

  # Module Variables
  name                = local.service_plan_name
  resource_group_name = module.resource_group.name

  resource_tags          = {
    environment = local.ws_name
  }
}

module "app_service" {
  # Module Path
  source = "github.com/danielscholl/iac-terraform/modules/app-service"

  # Module Variables
  name                       = local.app_service_name
  resource_group_name        = module.resource_group.name
  service_plan_name          = module.service_plan.name
  app_service_config         = local.app_services
  docker_registry_server_url = local.reg_url
  vault_uri                  = module.keyvault.uri
  app_settings               = {
    cosmosdb_database        = module.cosmosdb.name
    cosmosdb_account         = module.cosmosdb.endpoint
    cosmosdb_key             = module.cosmosdb.primary_master_key
  }

  resource_tags          = {
    environment = local.ws_name
  }
}


#-------------------------------
# Output Variables  (output.tf)
#-------------------------------
output "app_service_default_hostname" {
  value = "https://${element(module.app_service.uris, 0)}"
}
