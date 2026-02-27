# InstantPaymentBench

A benchmarking harness for measuring **SQL Server 2025** throughput under the write patterns typical of an instant payment system: concurrent fund transfers, double-entry ledger writes, idempotency enforcement, and high-contention balance reads.

The benchmark supports SQL Server on both **Windows Server 2025** and **RHEL 10.1**, enabling a fair, reproducible, cross-platform comparison under identical hardware, tuning, and load conditions.

---

## Domain Model

The system models a simplified instant payment ledger. The database schema contains three tables:

| Table | Purpose |
|---|---|
| `Account` | Holds 100,000 accounts, each with a `BalanceCents` balance. The first 10 accounts are seeded as "hot accounts" with a £10,000,000 opening balance to act as high-volume payers. |
| `Transfer` | Records a payment instruction from one account to another, with an `IdempotencyKey` (UUID) enforced via a unique index. Status values: `Committed`, `Rejected`. |
| `LedgerEntry` | A double-entry ledger: every committed transfer produces two rows — one debit (`D`) and one credit (`C`) — maintaining a complete audit trail. |

### Key Database Settings

The database is deliberately configured to reflect realistic production conditions rather than optimising artificially for benchmarks:

- **`RECOVERY FULL` + `DELAYED_DURABILITY = DISABLED`** — every `COMMIT` flushes the transaction log synchronously, as required in payment systems for durability guarantees.
- **`READ_COMMITTED_SNAPSHOT ON`** — readers do not block writers; allows balance reads to proceed without acquiring shared locks.
- **`ALLOW_SNAPSHOT_ISOLATION ON`** — explicit snapshot isolation is available for long-running read transactions.
- **`ACCELERATED_DATABASE_RECOVERY = ON`** and **`OPTIMIZED_LOCKING = ON`** — SQL Server 2025 features that reduce lock escalation and accelerate crash recovery.
- **`PARAMETERIZATION FORCED`** — all ad hoc queries are auto-parameterised to reduce plan cache pressure under high concurrency.

### Transfer Flow

A payment is executed in a single round-trip to the API (`POST /api/transfers/commit`). The endpoint opens a transaction and performs the following steps:

1. **Idempotency check** — queries the `Transfer` table using `WITH (UPDLOCK, HOLDLOCK)`, which elevates the statement to `SERIALIZABLE` isolation. If the UUID already exists, the original result is returned immediately. If it does not, SQL Server acquires a **range lock** (`RangeS-U`) on the empty space in the index where the row would sit, preventing any concurrent transaction from inserting the same key until the current transaction completes.
2. **Lock accounts in order** — acquires update locks on the sender and receiver `Account` rows, always in ascending `AccountId` order. This fixed ordering prevents deadlocks from inconsistent lock acquisition.
3. **Validate balance and debit/credit** — checks that the sender has sufficient funds, then debits the sender's `Account.BalanceCents` and credits the receiver's. Transfers where the balance is insufficient are recorded with `Status = Rejected` and returned as `HTTP 200` (business rejection, not an error).
4. **Insert Transfer and LedgerEntry rows** — records the transfer and inserts two `LedgerEntry` rows (one debit, one credit) for double-entry bookkeeping.
5. **Commit** — the transaction is committed with full durability (no delayed durability), and the transfer status is returned to the client.

If the database raises a **deadlock** (`SqlException 1205`), the API returns `503 Service Unavailable` with the error message. The k6 load generator detects this, increments a `deadlock_retries` counter, and backs off with a short random sleep before retrying — up to three attempts per VU iteration.

---

## Load Profile

The k6 script (`k6/main-exhaustion.js`) runs three concurrent scenarios simultaneously:

| Scenario | Default VUs | Behaviour |
|---|---|---|
| `commit_transfer` | `110 × VU_SCALE` | Posts a transfer from a hot account to a random account. Retries on deadlock. |
| `browse_balance` | `300 × VU_SCALE` | Reads the balance of a random account (`GET /api/accounts/:id/balance`). |
| `idempotency_replay` | `90 × VU_SCALE` | Re-submits a previously used `IdempotencyKey` to exercise the unique-constraint fast-path. |

All scenarios ramp up over 10 seconds, sustain load for 5 minutes, then ramp down. The baseline (`VU_SCALE=1`) generates approximately 500 concurrent virtual users.

### Contention Modes

The `HOT_ACCOUNTS_MODE` variable controls how transfers are distributed across the hot account pool:

- **`x10` (default)** — transfers are distributed randomly across all 10 hot accounts. This simulates a realistic mix of contention.
- **`x1`** — all transfers originate from a single hot account (`AccountId = 1`). This deliberately forces extreme row-level lock contention to stress-test deadlock handling and snapshot isolation.

---

## Architecture

All Azure VMs are deployed into a **Proximity Placement Group** in the same Availability Zone to minimise network latency between components:

```text
                          Azure Availability Zone (West US 2)
┌───────────────────────────────────────────────────────────────────────────────────┐
│  ┌─────────────────────────── Proximity Placement Group ───────────────────────┐  │
│  │                                                                             │  │
│  │   ┌───────────────┐        ┌───────────────────┐        ┌───────────────┐   │  │
│  │   │     VMK6      │ HTTP   │    VMENDPOINT     │  TDS   │   VMSQLWIN    │   │  │
│  │   │  (RHEL 10.1)  ├───────►│    (RHEL 10.1)    ├───────►│      or       │   │  │
│  │   │ Load Generator│        │ .NET 10 API (Kestrel)      │   VMSQLRHEL   │   │  │
│  │   │  (F4as_v6)    │        │    (D4ads_v6)     │        │ (E8ads_v7)    │   │  │
│  │   └───────┬───────┘        └─────────┬─────────┘        └───────┬───────┘   │  │
│  │           │                          │                          │           │  │
│  └───────────┼──────────────────────────┼──────────────────────────┼───────────┘  │
│              │                          │                          │              │
│      Accelerated Net            Accelerated Net            Accelerated Net        │
└──────────────┼──────────────────────────┼──────────────────────────┼──────────────┘
               │                          │                          │
               ▼                          ▼                          ▼
      ┌────────────────┐         ┌────────────────┐         ┌────────────────┐
      │   Premium LRS  │         │   Premium LRS  │         │ PremiumV2 LRS  │ Data [128GB, 5k  IOPS]
      │   (OS Disk)    │         │   (OS Disk)    │         │ PremiumV2 LRS  │ Log  [ 64GB, 3k  IOPS]
      │                │         │                │         │   NVMe Local   │ TempDB [~200GB, >100k IOPS]
      └────────────────┘         └────────────────┘         └────────────────┘
```

| VM | SKU | OS | Role |
|---|---|---|---|
| `VMSQLWIN` or `VMSQLRHEL` | Standard_E8ads_v7 (8 vCPU, 64 GB) | Windows Server 2025 or RHEL 10.1 | SQL Server 2025 |
| `VMENDPOINT` | Standard_D4ads_v6 (4 vCPU, 16 GB) | RHEL 10.1 | .NET 10 API (AMD EPYC 9V45) |
| `VMK6` | Standard_F4as_v6 (4 vCPU, 8 GB) | RHEL 10.1 | k6 load generator (AMD EPYC 9V45) |

> [!NOTE]
> The VM sizes, families, and availability zones can be customized by modifying the `vms_sizes` variable in `terraform/01-foundation/main.tf`.

All VMs use **Accelerated Networking** and **NVMe disk controllers**. TempDB is placed on the NVMe local disk (ephemeral, high-IOPS) to avoid I/O contention with the transaction log and data files. The API is hosted purely on **Kestrel** (no reverse proxy like Nginx or IIS) to ensure maximum throughput and prevent HTTP routing overhead from skewing the database measurements.

### Storage Layout

| Volume | Disk Type | Size | IOPS / Throughput |
|---|---|---|---|
| Data files (`/mnt/sqldata` / `F:`) | PremiumV2 LRS | 128 GB | 5,000 IOPS / 200 MB/s |
| Log files (`/mnt/sqllog` / `G:`) | PremiumV2 LRS | 64 GB | 3,000 IOPS / 125 MB/s |
| TempDB (`/mnt/sqltempdb` / `D:`) | NVMe local | ~200 GB | >100k IOPS |

### SQL Server Instance Tuning

Both platforms are configured identically:

| Setting | Value |
|---|---|
| MAXDOP | 8 |
| Max Server Memory | 51,200 MB (50 GB) |
| Cost Threshold for Parallelism | 50 |
| Optimise for Ad Hoc Workloads | ON |
| Lock Pages in Memory | ON |
| Instant File Initialisation | ON |
| TempDB files | 8 × 512 MB |
| Collation | `SQL_Latin1_General_CP1_CI_AS` |

---

## Project Structure

```
bench-infra/
├── deploy.sh                        # Full interactive deployment
├── destroy.sh                       # Tear down all Azure infrastructure
├── terraform/
│   ├── 01-foundation/               # Resource group, VNet, PPG, zones
│   ├── 02-vm-sql-rhel/              # SQL Server VM (RHEL)
│   ├── 02-vm-sql-win/               # SQL Server VM (Windows)
│   └── 03-vm-linux/                 # Endpoint + k6 VMs; generates inventory
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini                # Generated by Terraform
│   ├── group_vars/                  # Generated by Terraform (credentials, IPs)
│   ├── templates/
│   └── playbooks/
│       ├── install-sqlserver-rhel.yml
│       ├── deploy-sql-rhel.yml      # Create DB, seed, backup
│       ├── deploy-sql-win.yml       # Create DB, seed, backup
│       ├── deploy-endpoint.yml      # Build and deploy .NET API
│       ├── deploy-k6.yml            # Deploy k6 scripts and run.sh
│       ├── setup-endpoint.yml       # OS settings, .NET SDK, firewall
│       ├── setup-k6.yml             # Install k6, sysctl tuning
│       ├── patch-linux.yml
│       ├── patch-windows.yml
│       └── run-benchmark.yml        # Orchestrated benchmark with metrics
├── sql/
│   ├── 00_create_database.sql       # Schema definition
│   ├── 01_seed.sql                  # 100k accounts
│   ├── 02_query_ids.sql             # Extracts hot account IDs for k6
│   ├── fingerprint.sql              # Pre-run instance configuration snapshot
│   ├── xe_create.sql                # Extended Events deadlock session
│   ├── xe_start.sql
│   ├── xe_stop.sql
│   └── xe_export_deadlocks.sql      # Exports deadlock graphs to XML
├── endpoint/
│   ├── InstantPaymentBench.Api/
│   ├── InstantPaymentBench.Application/
│   └── InstantPaymentBench.Infrastructure/
└── k6/
    └── main-exhaustion.js           # Load test scenarios
```

---

## Prerequisites

The control node (your local machine) requires:

### Terraform (>= 1.5)

[Download Terraform](https://developer.hashicorp.com/terraform/downloads)

### Ansible and Dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate

pip install --upgrade pip
pip install ansible-core requests pywinrm requests-ntlm pyspnego cryptography xmltodict jmespath

ansible-galaxy collection install ansible.windows community.windows community.general ansible.posix microsoft.sql
```

### Azure CLI

> [!IMPORTANT]
> The Azure CLI must be installed and you must be authenticated before running `deploy.sh` or `destroy.sh`. Terraform uses the Azure CLI credential chain — without an active session, all Terraform commands will fail immediately with an authentication error.

Install the CLI by following the [official guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli), then authenticate:

```bash
az login
```

Verify the correct subscription is active before proceeding:

```bash
az account show --query "{name:name, id:id}" -o table
```

---

## Deployment

The `deploy.sh` script orchestrates the full environment: it prompts for the SQL Server platform (Windows or RHEL), provisions Azure infrastructure via Terraform, configures all VMs via Ansible, installs SQL Server, seeds the database, and deploys the API and k6 agent.

> [!NOTE]
> **Windows Server Updates:** The script supports updating Windows Server 2025 automatically. However, because Ansible applies updates over WinRM, this process is significantly slower than native patching. It is highly recommended to perform updates manually via Windows Terminal Services (RDP). If you opt for the automatic route via the script, please double-check that all updates have been successfully applied, as large cumulative updates can sometimes cause WinRM timeouts.

```bash
chmod +x deploy.sh destroy.sh

# Full deploy — interactive prompts for OS choice, subscription, and update preferences
./deploy.sh

# Use Azure Spot instances (lower cost, interruptible)
./deploy.sh --spot=yes
```

> [!WARNING]
> **Spot instances are not recommended for benchmark data collection.** Spot VMs can be evicted mid-test, causing incomplete runs and data loss. Use Spot only for development, debugging, and validating the pipeline. For final benchmark runs intended for publication or decision-making, always use on-demand instances.

# Skip OS patching to speed up redeployments (saves ~15–30 minutes)
./deploy.sh --skip-patch

# Terraform only — skip Ansible configuration
./deploy.sh --infra-only
```

---

## Running a Benchmark

### Orchestrated Run (recommended)

The `run-benchmark.yml` playbook, executed directly from your Linux local machine, manages the full test lifecycle: capturing wait statistics before and after the run, clearing telemetry, optionally enabling Extended Events deadlock capture, executing k6, and collecting all artefacts locally.

```bash
cd ansible

# Standard run with diagnostics
ansible-playbook -i inventory.ini playbooks/run-benchmark.yml \
  -e "k6_script=main-exhaustion.js vu_scale=1 diag=1"

# With Extended Events deadlock collection
ansible-playbook -i inventory.ini playbooks/run-benchmark.yml \
  -e "k6_script=main-exhaustion.js vu_scale=1 diag=1 xe=1 clear_waits=1"
```

Results are saved to `ansible/results/<run_id>/` and include:
- `wait_stats_before_*.csv` / `wait_stats_after_*.csv` — `sys.dm_os_wait_stats` snapshots
- `sql_fingerprint_*.txt` — instance configuration at time of run
- `k6_*.log` — full k6 console output
- `xe/xe_deadlocks_*.xml` — deadlock graphs (if `xe=1`)
- `xe/raw/*.xel` — raw Extended Events files

### Manual Run (SSH into k6 VM)

```bash
# Default scale (110 transfer VUs + 300 read VUs + 90 idempotency VUs)
/opt/k6/run.sh main-exhaustion.js

# Scale up all VU counts by a multiplier
VU_SCALE=5  /opt/k6/run.sh main-exhaustion.js
VU_SCALE=10 /opt/k6/run.sh main-exhaustion.js

# Force single hot-account contention (stress-tests deadlock handling)
HOT_ACCOUNTS_MODE=x1 VU_SCALE=10 /opt/k6/run.sh main-exhaustion.js
```

---

## Resetting Between Tests

> [!IMPORTANT]
> **The database must be reset before every benchmark run.** The benchmark does not reset the database automatically. Running `run-benchmark.yml` against a database that already contains transactional data from a previous run will produce skewed results — `Transfer` and `LedgerEntry` rows from the previous run will be included in wait-stats and row-count baselines.

The reset performs a full `DROP DATABASE` / `CREATE DATABASE` / seed cycle, restoring the schema and the 100,000 seeded accounts with their original balances. All `Transfer` and `LedgerEntry` rows are discarded.

**RHEL SQL:**
```bash
cd ~/bench/temp/ansible
ansible-playbook playbooks/deploy-sql-rhel.yml --tags reset
```

**Windows SQL:**
```bash
cd ~/bench/temp/ansible
ansible-playbook playbooks/deploy-sql-win.yml --tags reset
```

Once the reset completes, run the benchmark immediately afterwards:

```bash
ansible-playbook -i inventory.ini playbooks/run-benchmark.yml \
  -e "k6_script=main-exhaustion.js vu_scale=5 xe=1 clear_waits=1 diag=1"
```

The `db_recreated.txt` file written to each result directory records the row counts at the moment the benchmark started. Before a valid run, it should always read:

```
Account      100000
LedgerEntry       0
Transfer          0
```

If `LedgerEntry` or `Transfer` are non-zero, the reset was either skipped or failed silently — the results for that run should be discarded.

---

## Redeploying After Code Changes

Push updated application code or k6 scripts without tearing down infrastructure:

```bash
cd ansible
ansible-playbook playbooks/deploy-endpoint.yml   # Rebuild and redeploy .NET API
ansible-playbook playbooks/deploy-k6.yml          # Redeploy k6 scripts
```

---

## Credentials

```bash
# SQL Server VM
cd terraform/02-vm-sql-rhel   # or 02-vm-sql-win
terraform output -raw vm_admin_password
terraform output -raw sql_admin_password

# Endpoint and k6 VMs
cd terraform/03-vm-linux
terraform output -raw linux_admin_password
terraform output ssh_connect_endpoint
terraform output ssh_connect_k6
```

---

## Teardown

```bash
./destroy.sh
```

---

## Design Decisions & Findings from the Trenches

- **Durability over speed** — `RECOVERY FULL` with `DELAYED_DURABILITY = DISABLED` ensures every committed transaction pays the full log-flush cost. A good part of production financial systems require this level of durability because the trade-off — acknowledging a payment before it is physically persisted — is unacceptable when real money is at stake. The benchmark reflects this constraint rather than optimising it away.
- **RCSI always on** — `READ_COMMITTED_SNAPSHOT` eliminates shared-lock contention on balance reads, allowing read and write workloads to run concurrently without reader–writer blocking.
- **Idempotency via UPDLOCK + HOLDLOCK on a unique index** — the `IdempotencyKey` column carries a unique nonclustered index. Before inserting a new transfer, the endpoint queries the index `WITH (UPDLOCK, HOLDLOCK)`, elevating the statement to `SERIALIZABLE` isolation. For new UUIDs, SQL Server must lock the "empty space" in the index where the row would sit (a **range lock**, `RangeS-U`). Under high concurrency, hundreds of transactions queue for these range locks simultaneously, and the cumulative wait — reported as `LCK_M_RS_U` — constitutes the true throughput ceiling of this benchmark. A replay of the same key hits the existing row and returns the original result via the index fast-path.
- **Hot accounts as contention levers** — accounts 1–10 are seeded with a large balance and used as transfer originators. Distributing load across 10 hot accounts (`x10` mode) produces realistic multi-row contention; forcing all load to account 1 (`x1` mode) produces pathological single-row contention for isolation-mode comparison.
- **Ordered locking to prevent deadlocks** — accounts are always locked in ascending `AccountId` order. This classic technique proved remarkably effective: across all thirty test runs in the study (covering both platforms, all load levels, and all VM deployments), exactly one deadlock was recorded per run, every single time. That lone deadlock was absorbed by the client's exponential backoff with up to three retries.
- **Deadlock-aware client** — the API surfaces `SqlException 1205` as `503 Service Unavailable`. The k6 script intercepts this, increments `deadlock_retries`, and applies a small random back-off before retrying, mimicking a resilient payment client.
- **Identical tuning across platforms** — every `sp_configure` setting, TempDB file layout, memory boundary, and database option is applied identically on both Windows and Linux, ensuring that observed differences are attributable to the platform rather than configuration asymmetry.
- **Extended Events for deadlock forensics** — the orchestrator can attach a live XE session during the run and export deadlock graphs to XML for post-run analysis, without affecting the latency measurements collected by k6.

### Key Observations: Linux (SQLPAL) vs Windows

1. **The Target OS Image Trap and Noisy Neighbours**: The Azure Marketplace Windows image shipped with an older RTM-GDR build, while our RHEL installation pulled Cumulative Update 2 (CU2). Initially, this seemed to give CU2 a massive 2.6× performance lead at baseline. Re-validation on fresh VMs proved this was a **noisy neighbour artefact**. At low contention, the two builds perform identically. Always run `SELECT @@VERSION` and never trust a single cloud benchmark run.
2. **The Paradox of Log Stall**: Average log write stall (`WRITELOG`) on Linux is around 19.5% slower than on Windows. This is because the SQLPAL abstraction layer on Linux routes `fdatasync()` sys-calls to the XFS filesystem, whereas Windows leverages native kernel-mode NTFS drivers. *However*, under heavy saturation, **this I/O gap is completely irrelevant**. Transactions spend millions of milliseconds waiting in `LCK_M_RS_U` queues for range locks. The runway may be slightly slower, but the queue is what keeps you waiting.
3. **The `SOS_WORK_DISPATCHER` Stabilisation**: While baseline performance between GDR and CU2 is statistically identical, the internal `SOS_WORK_DISPATCHER` wait time is wildly unstable on the GDR build (ranging from 7.8M to 451M ms). Applying CU2 brings a measurable improvement in consistency to these internal scheduling waits, confirming the value of cumulative updates even without headline throughput gains.
4. **Conclusion**: At identical patch levels (CU2) and maximum saturation (2,500 VUs), **SQL Server on Linux delivered 3.3% higher throughput and a 9.0% lower p95 latency than Windows Server**. Despite the slight I/O penalty, Linux's CFS scheduler wakes threads fractionally sooner after lock grants, cycling them through the scheduler faster (indicated by 92% higher `SOS_SCHEDULER_YIELD`). This marginal efficiency, accumulated across tens of thousands of lock acquisitions, outscales the `WRITELOG` overhead. The SQLPAL abstraction holds surprisingly firm under severe contention. In practical terms, the performance of SQL Server on Windows and Linux is equivalent for the purpose of a migration decision. The differences observed in this study are too small to justify choosing one platform over the other on performance grounds alone.
