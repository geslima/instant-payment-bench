#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "This will destroy ALL resources. Are you sure? (yes/no)"
read -rp "> " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "=== 03-vm-linux ==="
cd "$SCRIPT_DIR/terraform/03-vm-linux"
terraform destroy -auto-approve

if [[ -f "$SCRIPT_DIR/terraform/02-vm-sql-win/terraform.tfstate" ]]; then
    echo ""
    echo "=== 02-vm-sql-win ==="
    cd "$SCRIPT_DIR/terraform/02-vm-sql-win"
    terraform destroy -auto-approve
fi

if [[ -f "$SCRIPT_DIR/terraform/02-vm-sql-rhel/terraform.tfstate" ]]; then
    echo ""
    echo "=== 02-vm-sql-rhel ==="
    cd "$SCRIPT_DIR/terraform/02-vm-sql-rhel"
    terraform destroy -auto-approve
fi

echo ""
echo "=== 01-foundation ==="
cd "$SCRIPT_DIR/terraform/01-foundation"
terraform destroy -auto-approve

echo ""
echo "=== All resources destroyed ==="
