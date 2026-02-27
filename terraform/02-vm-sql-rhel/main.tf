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

resource "azurerm_public_ip" "sqlrhel" {
  name                = "pip-vmsqlrhel"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.vm_sql.zone != null ? [local.vm_sql.zone] : []
}

resource "azurerm_network_interface" "sqlrhel" {
  name                           = "nic-vmsqlrhel"
  location                       = local.location
  resource_group_name            = local.rg_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.sqlrhel.id
  }
}

resource "azurerm_linux_virtual_machine" "sqlrhel" {
  name                = "VMSQLRHEL"
  resource_group_name = local.rg_name
  location            = local.location
  size                = local.vm_sql.size
  zone                = local.vm_sql.zone

  admin_username                  = var.admin_username
  admin_password                  = random_password.vm.result
  disable_password_authentication = false

  priority        = var.enable_spot ? "Spot" : "Regular"
  eviction_policy = var.enable_spot ? "Deallocate" : null
  max_bid_price   = var.enable_spot ? data.terraform_remote_state.foundation.outputs.spot_max_bid_price : -1

  proximity_placement_group_id = local.ppg_id

  disk_controller_type = "NVMe"

  network_interface_ids = [azurerm_network_interface.sqlrhel.id]

  os_disk {
    name                 = "osdisk-vmsqlrhel"
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

  boot_diagnostics {}
}

resource "azurerm_managed_disk" "data" {
  name                 = "disk-vmsqlrhel-data"
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
  virtual_machine_id = azurerm_linux_virtual_machine.sqlrhel.id
  lun                = 0
  caching            = "None"
}

resource "azurerm_managed_disk" "log" {
  name                 = "disk-vmsqlrhel-log"
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
  virtual_machine_id = azurerm_linux_virtual_machine.sqlrhel.id
  lun                = 1
  caching            = "None"
}

locals {
  disk_init_script = <<-BASH






exec > /var/log/disk-init.log 2>&1
set -x

echo "=== Starting disk init at $(date) ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL


echo never > /sys/kernel/mm/transparent_hugepage/enabled  || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag   || true


XFS_OPTS="noatime,nodiratime,logbsize=256k,nofail"


find_raw_nvme_by_size_gb() {
  local target_gb=$1
  local target_bytes=$((target_gb * 1073741824))
  for dev in $(lsblk -dbnpo NAME,SIZE | awk -v sz="$target_bytes" '$2==sz {print $1}'); do

    local children
    children=$(lsblk -npo NAME "$dev" | tail -n +2 | wc -l)
    if [ "$children" -eq 0 ]; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}





find_nvme_local() {
  for dev in /dev/nvme*n1; do
    [ -b "$dev" ] || continue


    local model=""
    model=$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null | xargs) || true


    if [ -z "$model" ]; then
      local ctrl
      ctrl=$(basename "$(readlink -f "/sys/block/$(basename "$dev")/device")" 2>/dev/null) || true
      model=$(cat "/sys/class/nvme/$${ctrl}/model" 2>/dev/null | xargs) || true
    fi

    echo "  Checking $dev model='$model'"


    if echo "$model" | grep -qiE "Direct Disk|Local Disk|Ephemeral"; then
      echo "$dev"
      return 0
    fi


    if echo "$model" | grep -qi "NVMe" && ! echo "$model" | grep -qi "Accelerator"; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}


DATA_DEV=$(find_raw_nvme_by_size_gb 128) || true
if [ -n "$DATA_DEV" ]; then
  echo "Formatting data disk: $DATA_DEV"
  mkfs.xfs -f "$DATA_DEV"
  mkdir -p /mnt/sqldata
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  echo "UUID=$UUID /mnt/sqldata xfs $XFS_OPTS 0 2" >> /etc/fstab
  mount /mnt/sqldata
  echo "Data disk mounted: $DATA_DEV -> /mnt/sqldata"
else
  echo "ERROR: Data disk (128GB) not found!"
fi


LOG_DEV=$(find_raw_nvme_by_size_gb 64) || true
if [ -n "$LOG_DEV" ]; then
  echo "Formatting log disk: $LOG_DEV"
  mkfs.xfs -f "$LOG_DEV"
  mkdir -p /mnt/sqllog
  UUID=$(blkid -s UUID -o value "$LOG_DEV")
  echo "UUID=$UUID /mnt/sqllog xfs $XFS_OPTS 0 2" >> /etc/fstab
  mount /mnt/sqllog
  echo "Log disk mounted: $LOG_DEV -> /mnt/sqllog"
else
  echo "ERROR: Log disk (64GB) not found!"
fi




mkdir -p /mnt/sqltempdb
TEMP_DEV=$(find_nvme_local) || true
if [ -n "$TEMP_DEV" ]; then
  for m in $(findmnt -rn -o TARGET -S "$TEMP_DEV" 2>/dev/null); do
    if [ "$m" != "/mnt/sqltempdb" ]; then umount "$m" || true; fi
  done
  echo "Formatting NVMe local for TempDB: $TEMP_DEV"
  mkfs.xfs -f "$TEMP_DEV"
  mount -o noatime,nodiratime "$TEMP_DEV" /mnt/sqltempdb
  echo "NVMe local mounted: $TEMP_DEV -> /mnt/sqltempdb"
else
  echo "WARNING: NVMe local disk not found. TempDB will use OS disk."
fi


chmod 755 /mnt/sqldata /mnt/sqllog /mnt/sqltempdb 2>/dev/null || true

echo "=== Disk init complete ==="
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL
df -h /mnt/sqldata /mnt/sqllog /mnt/sqltempdb 2>/dev/null || true
BASH
}

resource "azurerm_virtual_machine_extension" "disk_init" {
  name                 = "disk-init"
  virtual_machine_id   = azurerm_linux_virtual_machine.sqlrhel.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.data,
    azurerm_virtual_machine_data_disk_attachment.log,
  ]

  protected_settings = jsonencode({
    script = base64encode(local.disk_init_script)
  })

  timeouts {
    create = "15m"
  }
}

output "vm_public_ip" {
  value = azurerm_public_ip.sqlrhel.ip_address
}

output "vm_private_ip" {
  value = azurerm_network_interface.sqlrhel.private_ip_address
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
