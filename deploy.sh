#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="terraform.tfvars"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
INFRA_ONLY=false
SKIP_PATCH=false
SQL_OS=""
DO_LINUX_UPDATE="false"
DO_SQL_LINUX_UPDATE="false"
DO_WINDOWS_UPDATE="false"
ENABLE_SPOT=false

usage() {
    echo "Usage: $0 [--infra-only] [--skip-patch] [--spot=yes]"
    echo ""
    echo "  --infra-only   Only run Terraform (skip Ansible)"
    echo "  --skip-patch   Skip OS patching (saves ~15-30 min)"
    echo "  --spot=yes     Provision VMs using Azure Spot instances"
    echo ""
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --infra-only) INFRA_ONLY=true ;;
        --skip-patch) SKIP_PATCH=true ;;
        --spot=yes)   ENABLE_SPOT=true ;;
        --help|-h)    usage ;;
        *)            echo "Unknown option: $arg"; usage ;;
    esac
done

banner() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════"
}

run_playbook() {
    local playbook="$1"
    shift
    banner "Ansible: $(basename "$playbook" .yml)"
    cd "$ANSIBLE_DIR"
    ansible-playbook "playbooks/$playbook" "$@"
}

banner "SQL Server Operating System"
echo ""
echo "  [1] Windows Server 2025"
echo "  [2] Red Hat Enterprise Linux 10.1"
echo ""
read -rp "Which OS for the SQL Server VM? (1 or 2): " OS_CHOICE

case "$OS_CHOICE" in
    1)
        SQL_OS="windows"
        SQL_DIR="02-vm-sql-win"
        echo "Selected: Windows Server 2025"
        ;;
    2)
        SQL_OS="rhel"
        SQL_DIR="02-vm-sql-rhel"
        echo "Selected: RHEL 10.1"
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

if [[ "$SKIP_PATCH" == false ]]; then
    banner "OS Updates Configuration"
    echo ""
    read -rp "Apply Linux OS updates on Endpoint + K6 VMs? (y/N): " RUN_LINUX_UPDATES
    if [[ "$RUN_LINUX_UPDATES" == "y" || "$RUN_LINUX_UPDATES" == "Y" ]]; then
        DO_LINUX_UPDATE="true"
    fi

    if [[ "$SQL_OS" == "rhel" ]]; then
        read -rp "Apply Linux OS updates on SQL RHEL VM? (y/N): " RUN_SQL_LINUX_UPDATES
        if [[ "$RUN_SQL_LINUX_UPDATES" == "y" || "$RUN_SQL_LINUX_UPDATES" == "Y" ]]; then
            DO_SQL_LINUX_UPDATE="true"
        fi
    fi

    if [[ "$SQL_OS" == "windows" ]]; then
        read -rp "Apply Windows Updates to SQL VM? (y/N): " RUN_WIN_UPDATES
        if [[ "$RUN_WIN_UPDATES" == "y" || "$RUN_WIN_UPDATES" == "Y" ]]; then
            DO_WINDOWS_UPDATE="true"
        fi
    fi
    echo ""
fi

banner "Terraform — Subscription ID"

if [[ -f "$SCRIPT_DIR/terraform/01-foundation/$TFVARS_FILE" ]]; then
    EXISTING_SUB=$(grep subscription_id "$SCRIPT_DIR/terraform/01-foundation/$TFVARS_FILE" | cut -d'"' -f2 || true)
    if [[ -n "$EXISTING_SUB" ]]; then
        echo "Subscription ID already configured: $EXISTING_SUB"
        read -rp "Use this? (y/n): " USE_EXISTING
        if [[ "$USE_EXISTING" != "y" ]]; then
            read -rp "Enter Azure Subscription ID: " SUB_ID
        else
            SUB_ID="$EXISTING_SUB"
        fi
    else
        read -rp "Enter Azure Subscription ID: " SUB_ID
    fi
else
    read -rp "Enter Azure Subscription ID: " SUB_ID
fi

echo "subscription_id = \"$SUB_ID\"" > "$SCRIPT_DIR/terraform/01-foundation/$TFVARS_FILE"
echo "subscription_id = \"$SUB_ID\"" > "$SCRIPT_DIR/terraform/$SQL_DIR/$TFVARS_FILE"

cat > "$SCRIPT_DIR/terraform/03-vm-linux/$TFVARS_FILE" <<EOF
subscription_id = "$SUB_ID"
sql_state_path  = "../$SQL_DIR/terraform.tfstate"
sql_os_type     = "$SQL_OS"
EOF

if [[ "$ENABLE_SPOT" == true ]]; then
    echo "enable_spot = true" >> "$SCRIPT_DIR/terraform/01-foundation/$TFVARS_FILE"
    echo "enable_spot = true" >> "$SCRIPT_DIR/terraform/$SQL_DIR/$TFVARS_FILE"
    echo "enable_spot = true" >> "$SCRIPT_DIR/terraform/03-vm-linux/$TFVARS_FILE"
fi

echo "terraform.tfvars written to all directories."

banner "Terraform: 01-foundation"
cd "$SCRIPT_DIR/terraform/01-foundation"
terraform init -input=false
terraform apply -auto-approve

banner "Terraform: $SQL_DIR"
cd "$SCRIPT_DIR/terraform/$SQL_DIR"
terraform init -input=false
terraform apply -auto-approve

banner "Terraform: 03-vm-linux"
cd "$SCRIPT_DIR/terraform/03-vm-linux"
terraform init -input=false
terraform apply -auto-approve

banner "Terraform complete"
echo "Generated Ansible files:"
echo "  - ansible/inventory.ini"
echo "  - ansible/group_vars/linux.yml"
echo "  - ansible/group_vars/sql.yml"
echo "  - ansible/group_vars/endpoint.yml"

if [[ "$INFRA_ONLY" == true ]]; then
    echo ""
    echo "--infra-only specified. Skipping Ansible."
    echo "Run manually:  cd ansible && ansible-playbook playbooks/..."
    exit 0
fi

banner "Waiting for VMs to be reachable"

cd "$ANSIBLE_DIR"

echo "Waiting for Linux VMs (SSH)..."
for attempt in $(seq 1 10); do
    _RC=0
    ansible linux -m ping --timeout=30 -o || _RC=$?
    if [[ $_RC -eq 0 ]]; then
        echo "  Linux VMs reachable."
        break
    fi
    if [[ $_RC -ne 4 ]]; then
        echo "ERROR: Ansible failed with a non-connectivity error (rc=$_RC). Aborting."
        exit 1
    fi
    if [[ $attempt -eq 10 ]]; then
        echo "ERROR: Linux VMs not reachable after 10 attempts."
        exit 1
    fi
    echo "  Attempt $attempt/10 — waiting 15s..."
    sleep 15
done

if [[ "$SQL_OS" == "windows" ]]; then
    echo ""
    echo "Waiting for SQL VM (WinRM)..."
    for attempt in $(seq 1 20); do
        _RC=0
        ansible sql_win -m ansible.windows.win_ping --timeout=60 -o || _RC=$?
        if [[ $_RC -eq 0 ]]; then
            echo "  SQL VM reachable."
            break
        fi
        if [[ $_RC -ne 4 ]]; then
            echo "ERROR: Ansible failed with a non-connectivity error (rc=$_RC). Aborting."
            exit 1
        fi
        if [[ $attempt -eq 20 ]]; then
            echo "ERROR: SQL VM not reachable after 20 attempts."
            echo "Check Azure portal for CustomScriptExtension status."
            exit 1
        fi
        echo "  Attempt $attempt/20 — waiting 30s..."
        sleep 30
    done
else
    echo ""
    echo "Waiting for SQL VM (SSH)..."
    for attempt in $(seq 1 10); do
        _RC=0
        ansible sql_linux -m ping --timeout=30 -o || _RC=$?
        if [[ $_RC -eq 0 ]]; then
            echo "  SQL VM reachable."
            break
        fi
        if [[ $_RC -ne 4 ]]; then
            echo "ERROR: Ansible failed with a non-connectivity error (rc=$_RC). Aborting."
            exit 1
        fi
        if [[ $attempt -eq 10 ]]; then
            echo "ERROR: SQL VM not reachable after 10 attempts."
            exit 1
        fi
        echo "  Attempt $attempt/10 — waiting 15s..."
        sleep 15
    done
fi

echo ""
echo "All VMs reachable."

if [[ "$SKIP_PATCH" == true ]]; then
    banner "Skipping OS patching (--skip-patch)"
else
    if [[ "$SQL_OS" == "windows" ]]; then
        banner "Patching OS"

        cd "$ANSIBLE_DIR"
        
        banner "Patching Linux VMs (endpoint + k6)"
        ansible-playbook playbooks/patch-linux.yml -e do_linux_update=$DO_LINUX_UPDATE || echo "WARNING: Linux patching failed (non-fatal)."
        
        if [[ "$DO_WINDOWS_UPDATE" == "true" ]]; then
            banner "Patching Windows SQL VM"
            ansible-playbook playbooks/patch-windows.yml -e do_windows_update=true || { echo "ERROR: Windows patching failed."; exit 1; }
            echo "Wait 10 seconds before continuing..."
            sleep 10
        else
            echo "Skipping Windows Updates."
        fi
    else
        banner "Patching Linux VMs (endpoint + k6)"
        cd "$ANSIBLE_DIR"
        ansible-playbook playbooks/patch-linux.yml -e do_linux_update=$DO_LINUX_UPDATE || echo "WARNING: Linux patching failed (non-fatal)."
    fi
fi

if [[ "$SQL_OS" == "rhel" ]]; then
    run_playbook install-sqlserver-rhel.yml -e "do_linux_update=$DO_SQL_LINUX_UPDATE" -v
fi

run_playbook setup-endpoint.yml
run_playbook setup-k6.yml

if [[ "$SQL_OS" == "windows" ]]; then
    run_playbook deploy-sql-win.yml
else
    run_playbook deploy-sql-rhel.yml
fi

run_playbook deploy-endpoint.yml
run_playbook deploy-k6.yml

K6_IP=$(cd "$SCRIPT_DIR/terraform/03-vm-linux" && terraform output -raw k6_public_ip 2>/dev/null || echo "<k6-ip>")

banner "Deploy complete — environment ready!"
echo ""
echo "SQL Server OS: $(if [[ "$SQL_OS" == "windows" ]]; then echo "Windows Server 2025"; else echo "RHEL 10.1"; fi)"
echo ""
echo "Run a test:"
echo "  ssh benchadmin@$K6_IP"
echo "  /opt/k6/run.sh main-exhaustion.js"
echo ""
echo "Scale up:"
echo "  VU_SCALE=10 /opt/k6/run.sh main-exhaustion.js"
echo "  VU_SCALE=20 /opt/k6/run.sh main-exhaustion.js"
echo ""
echo "Reset between tests:"
if [[ "$SQL_OS" == "windows" ]]; then
    echo "  cd ansible && ansible-playbook playbooks/deploy-sql-win.yml --tags reset"
else
    echo "  cd ansible && ansible-playbook playbooks/deploy-sql-rhel.yml --tags reset"
fi
echo ""
echo "Re-deploy after code changes:"
echo "  cd ansible && ansible-playbook playbooks/deploy-endpoint.yml"
echo ""
