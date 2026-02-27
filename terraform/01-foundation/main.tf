terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14.0"
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

variable "location" {
  type    = string
  default = "West US 2"
}

variable "spot_max_bid_price" {
  type    = number
  default = 0.20
}

variable "vm" {
  type = object({
    endpoint = object({ size = string, zone = optional(string) })
    sql      = object({ size = string, zone = optional(string) })
    k6       = object({ size = string, zone = optional(string) })
  })
  default = {
    endpoint = { size = "Standard_D4ads_v7", zone = "1" }
    sql      = { size = "Standard_E8ads_v7", zone = "1" }
    k6       = { size = "Standard_F4as_v7", zone = "1" }
  }
  validation {
    condition = (
      length(var.vm.endpoint.size) > 0 && length(var.vm.sql.size) > 0 && length(var.vm.k6.size) > 0 &&
      (var.vm.endpoint.zone == null || try(contains(["1", "2", "3"], var.vm.endpoint.zone), false)) &&
      (var.vm.sql.zone == null || try(contains(["1", "2", "3"], var.vm.sql.zone), false)) &&
      (var.vm.k6.zone == null || try(contains(["1", "2", "3"], var.vm.k6.zone), false))
    )
    error_message = "VM sizes must be non-empty and zones must be '1', '2', '3', or null."
  }
}

variable "resource_group_name" {
  type    = string
  default = "BenchTest"
}





resource "azurerm_resource_group" "bench" {
  name     = var.resource_group_name
  location = var.location



  lifecycle {
    ignore_changes = [location]
  }
}





resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-bench"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name


  timeouts {
    create = "30m"
    update = "30m"
    read   = "5m"
    delete = "30m"
  }
}

resource "azurerm_subnet" "subnet" {
  name                 = "snet-bench-1"
  resource_group_name  = azurerm_resource_group.bench.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]

  timeouts {
    create = "30m"
    update = "30m"
    read   = "10m" # Resolve o read-back pós-create para eventual consistency
    delete = "30m"
  }
}





resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-bench"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name

  security_rule {
    name                       = "Allow-RDP"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SQL-Internal"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "10.10.0.0/16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-WinRM"
    priority                   = 1030
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5985"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id


  depends_on = [
    azurerm_virtual_network.vnet,
    azurerm_subnet.subnet,
    azurerm_network_security_group.nsg
  ]
}





resource "azurerm_proximity_placement_group" "ppg" {
  name                = "ppg_test"
  location            = azurerm_resource_group.bench.location
  resource_group_name = azurerm_resource_group.bench.name
  zone                = var.vm.sql.zone

  allowed_vm_sizes = [
    var.vm.sql.size,
    var.vm.endpoint.size,
    var.vm.k6.size,
  ]
}





output "resource_group_name" {
  value = azurerm_resource_group.bench.name
}

output "location" {
  value = azurerm_resource_group.bench.location
}

output "vm" {
  value = var.vm
}

output "subnet_id" {
  value = azurerm_subnet.subnet.id
}

output "ppg_id" {
  value = azurerm_proximity_placement_group.ppg.id
}

output "nsg_name" {
  value = azurerm_network_security_group.nsg.name
}

output "spot_max_bid_price" {
  value = var.spot_max_bid_price
}
