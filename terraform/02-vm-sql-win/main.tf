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
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "enable_spot" {
  type    = bool
  default = false
}

variable "admin_username" {
  type    = string
  default = "benchadmin"
}

data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../01-foundation/terraform.tfstate"
  }
}

locals {
  rg_name   = data.terraform_remote_state.foundation.outputs.resource_group_name
  location  = data.terraform_remote_state.foundation.outputs.location
  vm_sql    = data.terraform_remote_state.foundation.outputs.vm.sql
  subnet_id = data.terraform_remote_state.foundation.outputs.subnet_id
  ppg_id    = data.terraform_remote_state.foundation.outputs.ppg_id
}

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "@#"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "sql" {
  length           = 24
  special          = true
  override_special = "@#"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_public_ip" "sqlwin" {
  name                = "pip-vmsqlwin"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.vm_sql.zone != null ? [local.vm_sql.zone] : []
}

resource "azurerm_network_interface" "sqlwin" {
  name                           = "nic-vmsqlwin"
  location                       = local.location
  resource_group_name            = local.rg_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.sqlwin.id
  }
}

resource "azurerm_windows_virtual_machine" "sqlwin" {
  name                = "VMSQLWIN"
  resource_group_name = local.rg_name
  location            = local.location
  size                = local.vm_sql.size
  zone                = local.vm_sql.zone

  admin_username = var.admin_username
  admin_password = random_password.vm.result

  priority        = var.enable_spot ? "Spot" : "Regular"
  eviction_policy = var.enable_spot ? "Deallocate" : null
  max_bid_price   = var.enable_spot ? data.terraform_remote_state.foundation.outputs.spot_max_bid_price : -1

  proximity_placement_group_id = local.ppg_id


  disk_controller_type = "NVMe"

  network_interface_ids = [azurerm_network_interface.sqlwin.id]

  os_disk {
    name                 = "osdisk-vmsqlwin"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2025-ws2025"
    sku       = "entdev-gen2"
    version   = "17.0.251204"
  }

  boot_diagnostics {}
}

resource "azurerm_managed_disk" "data" {
  name                 = "disk-vmsqlwin-data"
  location             = local.location
  resource_group_name  = local.rg_name
  storage_account_type = "PremiumV2_LRS"
  create_option        = "Empty"
  disk_size_gb         = 128
  disk_iops_read_write = 5000
  disk_mbps_read_write = 200
  zone                 = local.vm_sql.zone
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_windows_virtual_machine.sqlwin.id
  lun                = 0
  caching            = "None"
}

resource "azurerm_managed_disk" "log" {
  name                 = "disk-vmsqlwin-log"
  location             = local.location
  resource_group_name  = local.rg_name
  storage_account_type = "PremiumV2_LRS"
  create_option        = "Empty"
  disk_size_gb         = 64
  disk_iops_read_write = 3000
  disk_mbps_read_write = 125
  zone                 = local.vm_sql.zone
}

resource "azurerm_virtual_machine_data_disk_attachment" "log" {
  managed_disk_id    = azurerm_managed_disk.log.id
  virtual_machine_id = azurerm_windows_virtual_machine.sqlwin.id
  lun                = 1
  caching            = "None"
}

locals {
  init_script = <<-PS
    Add-MpPreference -ExclusionPath "F:\\data"
    Add-MpPreference -ExclusionPath "G:\\log"
    Add-MpPreference -ExclusionPath "D:\\tempDb"
    Add-MpPreference -ExclusionPath "C:\\Program Files\\Microsoft SQL Server"
    Add-MpPreference -ExclusionExtension ".mdf"
    Add-MpPreference -ExclusionExtension ".ndf"
    Add-MpPreference -ExclusionExtension ".ldf"
    Add-MpPreference -ExclusionExtension ".bak"
    Add-MpPreference -ExclusionExtension ".trn"
    Add-MpPreference -ExclusionProcess "sqlservr.exe"
    Add-MpPreference -ExclusionProcess "fdhost.exe"
    Add-MpPreference -ExclusionProcess "fdlauncher.exe"
    Add-MpPreference -ExclusionProcess "sqlagent.exe"

    $dvd = Get-WmiObject -Class Win32_volume -Filter "DriveLetter='D:'"
    if ($dvd) {
      Set-WmiInstance -InputObject $dvd -Arguments @{DriveLetter='Z:'}
    }

    $nvme = Get-Disk | Where-Object {$_.FriendlyName -like '*NVMe Direct*' -and $_.PartitionStyle -eq 'RAW'}
    if ($nvme) {
      Initialize-Disk -Number $nvme.Number -PartitionStyle GPT
      New-Partition -DiskNumber $nvme.Number -UseMaximumSize -DriveLetter D
      Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel "TempDB" -AllocationUnitSize 65536 -Confirm:$false
    }
    New-Item -ItemType Directory -Path "D:\tempDb" -Force

    winrm quickconfig -force
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/service/auth '@{Basic="true"}'
    Set-Item -Path WSMan:\localhost\MaxMemoryPerShellMB -Value 1024
    netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow
    Restart-Service WinRM
  PS
}

resource "azurerm_virtual_machine_extension" "init" {
  name                 = "init-sql"
  virtual_machine_id   = azurerm_windows_virtual_machine.sqlwin.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.data,
    azurerm_virtual_machine_data_disk_attachment.log,
  ]

  protected_settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -EncodedCommand ${textencodebase64(local.init_script, "UTF-16LE")}"
  })

  timeouts {
    create = "60m"
  }
}

resource "azurerm_mssql_virtual_machine" "sqlwin" {
  virtual_machine_id = azurerm_windows_virtual_machine.sqlwin.id
  sql_license_type   = "PAYG"

  depends_on = [
    azurerm_virtual_machine_extension.init,
  ]

  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_username = var.admin_username
  sql_connectivity_update_password = random_password.sql.result

  storage_configuration {
    disk_type             = "NEW"
    storage_workload_type = "OLTP"

    data_settings {
      default_file_path = "F:\\data"
      luns              = [0]
    }

    log_settings {
      default_file_path = "G:\\log"
      luns              = [1]
    }

    temp_db_settings {
      default_file_path      = "D:\\tempDb"
      luns                   = []
      data_file_count        = 8
      data_file_size_mb      = 512
      data_file_growth_in_mb = 256
      log_file_size_mb       = 256
    }
  }

  sql_instance {
    max_dop                              = 8
    adhoc_workloads_optimization_enabled = true
    collation                            = "SQL_Latin1_General_CP1_CI_AS"
    max_server_memory_mb                 = 51200
    min_server_memory_mb                 = 0
    lock_pages_in_memory_enabled         = false
    instant_file_initialization_enabled  = true
  }
}

output "vm_public_ip" {
  value = azurerm_public_ip.sqlwin.ip_address
}

output "vm_private_ip" {
  value = azurerm_network_interface.sqlwin.private_ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "vm_admin_password" {
  value     = random_password.vm.result
  sensitive = true
}

output "sql_admin_password" {
  value     = random_password.sql.result
  sensitive = true
}
