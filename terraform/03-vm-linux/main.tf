terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "benchadmin"
}

variable "sql_state_path" {
  type    = string
  default = "../02-vm-sql-win/terraform.tfstate"
}

variable "sql_os_type" {
  type    = string
  default = "windows"
}

variable "enable_spot" {
  type    = bool
  default = false
}

data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../01-foundation/terraform.tfstate"
  }
}

data "terraform_remote_state" "sql" {
  backend = "local"
  config = {
    path = var.sql_state_path
  }
}

locals {
  rg_name     = data.terraform_remote_state.foundation.outputs.resource_group_name
  location    = data.terraform_remote_state.foundation.outputs.location
  vm_endpoint = data.terraform_remote_state.foundation.outputs.vm.endpoint
  vm_k6       = data.terraform_remote_state.foundation.outputs.vm.k6
  subnet_id   = data.terraform_remote_state.foundation.outputs.subnet_id
  ppg_id      = data.terraform_remote_state.foundation.outputs.ppg_id
}

resource "random_password" "linux" {
  length           = 24
  special          = true
  override_special = "@#"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_public_ip" "endpoint" {
  name                = "pip-vmendpoint"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.vm_endpoint.zone != null ? [local.vm_endpoint.zone] : []
}

resource "azurerm_network_interface" "endpoint" {
  name                           = "nic-vmendpoint"
  location                       = local.location
  resource_group_name            = local.rg_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.endpoint.id
  }
}

resource "azurerm_linux_virtual_machine" "endpoint" {
  name                = "VMENDPOINT"
  resource_group_name = local.rg_name
  location            = local.location
  size                = local.vm_endpoint.size
  zone                = local.vm_endpoint.zone

  disk_controller_type = "NVMe"

  admin_username                  = var.admin_username
  admin_password                  = random_password.linux.result
  disable_password_authentication = false

  priority        = var.enable_spot ? "Spot" : "Regular"
  eviction_policy = var.enable_spot ? "Deallocate" : null
  max_bid_price   = var.enable_spot ? data.terraform_remote_state.foundation.outputs.spot_max_bid_price : -1

  proximity_placement_group_id = local.ppg_id





  network_interface_ids = [azurerm_network_interface.endpoint.id]

  os_disk {
    name                 = "osdisk-vmendpoint"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "10-lvm-gen2"
    version   = "10.1.2026011314"
  }

  patch_mode = "ImageDefault"
  boot_diagnostics {}
}

resource "azurerm_public_ip" "k6" {
  name                = "pip-vmk6"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.vm_k6.zone != null ? [local.vm_k6.zone] : []
}

resource "azurerm_network_interface" "k6" {
  name                           = "nic-vmk6"
  location                       = local.location
  resource_group_name            = local.rg_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.k6.id
  }
}

resource "azurerm_linux_virtual_machine" "k6" {
  name                = "VMK6"
  resource_group_name = local.rg_name
  location            = local.location
  size                = local.vm_k6.size
  zone                = local.vm_k6.zone

  disk_controller_type = "NVMe"

  admin_username                  = var.admin_username
  admin_password                  = random_password.linux.result
  disable_password_authentication = false

  priority        = var.enable_spot ? "Spot" : "Regular"
  eviction_policy = var.enable_spot ? "Deallocate" : null
  max_bid_price   = var.enable_spot ? data.terraform_remote_state.foundation.outputs.spot_max_bid_price : -1

  proximity_placement_group_id = local.ppg_id





  network_interface_ids = [azurerm_network_interface.k6.id]

  os_disk {
    name                 = "osdisk-vmk6"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "10-lvm-gen2"
    version   = "10.1.2026011314"
  }

  patch_mode = "ImageDefault"
  boot_diagnostics {}
}

resource "local_file" "inventory" {
  filename        = "../../ansible/inventory.ini"
  file_permission = "0644"
  content         = <<-INI
[endpoint]
${azurerm_public_ip.endpoint.ip_address}

[k6]
${azurerm_public_ip.k6.ip_address}

[sql]
${data.terraform_remote_state.sql.outputs.vm_public_ip}

[sql_linux:children]
${var.sql_os_type == "rhel" ? "sql" : ""}

[sql_win:children]
${var.sql_os_type == "windows" ? "sql" : ""}

[linux:children]
endpoint
k6
INI
}

resource "local_sensitive_file" "linux_vars" {
  filename        = "../../ansible/group_vars/linux.yml"
  file_permission = "0640"
  content         = <<-YAML
ansible_ssh_pass: "${random_password.linux.result}"
ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
YAML
}

locals {
  sql_vars_windows = <<-YAML
ansible_connection: winrm
ansible_port: 5985
ansible_winrm_transport: basic
ansible_winrm_server_cert_validation: ignore
ansible_password: "${data.terraform_remote_state.sql.outputs.vm_admin_password}"
sql_auth_password: "${data.terraform_remote_state.sql.outputs.sql_admin_password}"
YAML
  sql_vars_rhel    = <<-YAML
ansible_connection: ssh
ansible_ssh_pass: "${data.terraform_remote_state.sql.outputs.vm_admin_password}"
ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
ansible_become_password: "${data.terraform_remote_state.sql.outputs.vm_admin_password}"
sql_auth_password: "${data.terraform_remote_state.sql.outputs.sql_admin_password}"
YAML
}

resource "local_sensitive_file" "sql_vars" {
  filename        = "../../ansible/group_vars/sql.yml"
  file_permission = "0640"
  content         = var.sql_os_type == "windows" ? local.sql_vars_windows : local.sql_vars_rhel
}

resource "local_sensitive_file" "endpoint_vars" {
  filename        = "../../ansible/group_vars/endpoint.yml"
  file_permission = "0640"
  content         = <<-YAML
sql_private_ip: "${data.terraform_remote_state.sql.outputs.vm_private_ip}"
sql_auth_user: "${var.sql_os_type == "windows" ? "benchadmin" : "sa"}"
sql_auth_password: "${data.terraform_remote_state.sql.outputs.sql_admin_password}"
endpoint_private_ip: "${azurerm_network_interface.endpoint.private_ip_address}"
YAML
}

output "endpoint_public_ip" {
  value = azurerm_public_ip.endpoint.ip_address
}

output "k6_public_ip" {
  value = azurerm_public_ip.k6.ip_address
}

output "linux_admin_password" {
  value     = random_password.linux.result
  sensitive = true
}

output "ssh_connect_endpoint" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.endpoint.ip_address}"
}

output "ssh_connect_k6" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.k6.ip_address}"
}

output "endpoint_private_ip" {
  value = azurerm_network_interface.endpoint.private_ip_address
}
