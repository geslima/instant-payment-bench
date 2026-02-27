#!/usr/bin/env bash
set -euo pipefail

# ===== BenchTest Runbook (Windows Server 2025 SQL host) =====
# Adapted from runbook.sh (RHEL) — only the SQL host target changed to Windows.
# k6 and endpoint VMs remain on Linux.
#
# Changes vs RHEL version:
#   - SQL host: ansible.windows.win_shell (WinRM) instead of ansible.builtin.shell (SSH)
#   - Paths:    C:\temp\benchtest-* instead of /var/tmp/benchtest-*
#   - sqlcmd:   sqlcmd (in PATH) instead of /opt/mssql-tools18/bin/sqlcmd
#   - DIAG:     typeperf (CPU/disk) instead of vmstat/iostat; no biolatency equivalent
#   - Meta:     platform=windows tag for cross-platform analysis
#
# Prerequisites:
#   - Windows SQL host configured for Ansible via WinRM
#     (ConfigureRemotingForAnsible.ps1 + pywinrm on controller)
#   - Inventory must set ansible_connection=winrm for the sql group
#     Example inventory.ini:
#       [sql]
#       sqlwin01 ansible_host=10.0.1.10 ansible_connection=winrm ansible_winrm_transport=ntlm ansible_user=Administrator ansible_password=...
#       [k6]
#       k6linux01 ansible_host=10.0.2.10
#       [endpoint]
#       eplinux01 ansible_host=10.0.3.10

# --- Config (override via env if you want) ---
INV="${INV:-inventory-win.ini}"
SQL_GROUP="${SQL_GROUP:-sql}"
K6_GROUP="${K6_GROUP:-k6}"
EP_GROUP="${EP_GROUP:-endpoint}"

DB_NAME="${DB_NAME:-InstantPaymentBench}"
SQL_USER="${SQL_USER:-sa}"
# On Windows, sqlcmd.exe is in PATH after SQL Server install
SQLCMD="${SQLCMD:-sqlcmd}"

RESET_PLAYBOOK="${RESET_PLAYBOOK:-playbooks/deploy-sql-win.yml}"

SCALES_DEFAULT=(1 3 9)
if [[ -n "${SCALES:-}" ]]; then
  read -r -a SCALES_ARR <<< "${SCALES}"
else
  SCALES_ARR=("${SCALES_DEFAULT[@]}")
fi

DIAG="${DIAG:-0}"
DIAG_SECONDS="${DIAG_SECONDS:-120}"

RESULTS_DIR="${RESULTS_DIR:-results}"

# Windows temp base path (no trailing backslash)
WIN_METRICS='C:\temp\benchtest-metrics'
WIN_DIAG='C:\temp\benchtest-diag'

# ===== Helpers =====
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
require ansible
require ansible-playbook
require uuidgen

ts_utc() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

# --- win_sql: run a command on the Windows SQL host via win_shell ---
# Usage: win_sql "powershell or cmd commands here"
win_sql() {
  ansible -i "$INV" "$SQL_GROUP" -m ansible.windows.win_shell -a "$1"
}

# --- win_sqlcmd: run sqlcmd on the Windows SQL host ---
# Usage: win_sqlcmd "T-SQL query" "/path/to/output.csv" [extra_flags]
win_sqlcmd() {
  local query="$1"
  local outfile="${2:-}"
  local extra="${3:-}"
  local cmd="${SQLCMD} -S localhost -U ${SQL_USER} -P '{{ sql_auth_password }}' -C"
  if [[ -n "$outfile" ]]; then
    cmd="${cmd} -W -s \",\" -o \"${outfile}\""
  fi
  cmd="${cmd} ${extra} -Q \"${query}\""
  win_sql "$cmd"
}

# ===== SQL Host Functions (Windows via WinRM) =====

ensure_sql_dirs() {
  win_sql "
    New-Item -ItemType Directory -Force -Path '${WIN_METRICS}' | Out-Null
    New-Item -ItemType Directory -Force -Path '${WIN_DIAG}' | Out-Null
  "
}

# k6 dirs — still Linux, unchanged from RHEL version
ensure_k6_dirs() {
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.shell -b -a \
    'mkdir -p /var/tmp/benchtest-k6 && chmod 0777 /var/tmp/benchtest-k6'
}

reset_db() {
  ansible-playbook -i "$INV" "$RESET_PLAYBOOK" --tags reset
}

clear_waits() {
  win_sqlcmd "DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);" "" "-b -V 16"
}

# --- Snapshot functions: T-SQL is identical to RHEL, only paths + module change ---

snap_waits() {
  local run_id="$1" vu="$2" phase="$3"
  local outfile="${WIN_METRICS}\\${run_id}_vu${vu}_${phase}_waits.csv"
  win_sqlcmd "SET NOCOUNT ON;
SELECT SYSUTCDATETIME() AS captured_at_utc, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('WRITELOG','IO_COMPLETION','PAGEIOLATCH_SH','PAGEIOLATCH_EX','PAGEIOLATCH_UP',
'LCK_M_X','LCK_M_U','LCK_M_S','LCK_M_IS','LCK_M_IX','LCK_M_SCH_S','LCK_M_SCH_M',
'PAGELATCH_EX','PAGELATCH_SH','PAGELATCH_UP','SOS_SCHEDULER_YIELD')
ORDER BY wait_time_ms DESC;" "$outfile" "-b -V 16"
}

snap_io() {
  local run_id="$1" vu="$2" phase="$3"
  local outfile="${WIN_METRICS}\\${run_id}_vu${vu}_${phase}_io.csv"
  win_sqlcmd "SET NOCOUNT ON;
WITH vfs AS (SELECT * FROM sys.dm_io_virtual_file_stats(NULL,NULL)),
mf AS (
  SELECT database_id,file_id,type_desc,name AS logical_name,physical_name,CONVERT(decimal(18,2),size/128.0) AS size_mb
  FROM sys.master_files
)
SELECT SYSUTCDATETIME() AS captured_at_utc,
  DB_NAME(vfs.database_id) AS database_name,
  vfs.file_id,
  mf.type_desc,
  mf.logical_name,
  mf.physical_name,
  mf.size_mb,
  vfs.num_of_reads,
  vfs.io_stall_read_ms,
  CAST(1.0*vfs.io_stall_read_ms/NULLIF(vfs.num_of_reads,0) AS decimal(18,4)) AS avg_read_ms,
  vfs.num_of_writes,
  vfs.io_stall_write_ms,
  CAST(1.0*vfs.io_stall_write_ms/NULLIF(vfs.num_of_writes,0) AS decimal(18,4)) AS avg_write_ms
FROM vfs
JOIN mf ON mf.database_id=vfs.database_id AND mf.file_id=vfs.file_id
WHERE DB_NAME(vfs.database_id) IN ('${DB_NAME}','tempdb')
ORDER BY database_name,mf.type_desc,vfs.file_id;" "$outfile" "-b -V 16"
}

snap_log() {
  local run_id="$1" vu="$2" phase="$3"
  local outfile="${WIN_METRICS}\\${run_id}_vu${vu}_${phase}_log.csv"
  win_sqlcmd "SET NOCOUNT ON;
SELECT
  SYSUTCDATETIME() AS captured_at_utc,
  DB_NAME(ls.database_id) AS database_name,
  ls.recovery_model,
  ls.total_vlf_count,
  ls.active_vlf_count,
  ls.total_log_size_mb,
  ls.active_log_size_mb,
  ls.log_truncation_holdup_reason,
  ls.log_backup_time,
  ls.log_since_last_log_backup_mb,
  ls.log_since_last_checkpoint_mb,
  ls.log_min_lsn,
  ls.log_end_lsn,
  ls.log_checkpoint_lsn,
  ls.log_recovery_lsn,
  ls.log_state
FROM sys.dm_db_log_stats(DB_ID(N'${DB_NAME}')) AS ls;" "$outfile" "-b"
}

snap_perf() {
  local run_id="$1" vu="$2" phase="$3"
  local outfile="${WIN_METRICS}\\${run_id}_vu${vu}_${phase}_perf.csv"
  win_sqlcmd "SET NOCOUNT ON;
SELECT SYSUTCDATETIME() AS captured_at_utc, object_name, counter_name, instance_name, cntr_value, cntr_type
FROM sys.dm_os_performance_counters
WHERE
  (object_name LIKE '%:Databases' AND instance_name IN ('${DB_NAME}','tempdb') AND counter_name IN
    ('Log Flush Wait Time','Log Flush Waits/sec','Log Flushes/sec','Log Bytes Flushed/sec','Transactions/sec'))
  OR
  (object_name LIKE '%:SQL Statistics' AND instance_name='_Total' AND counter_name IN
    ('Batch Requests/sec','SQL Compilations/sec','SQL Re-Compilations/sec'))
  OR
  (object_name LIKE '%:Locks' AND instance_name IN ('_Total','${DB_NAME}') AND counter_name IN
    ('Lock Waits/sec','Lock Wait Time (ms)','Number of Deadlocks/sec'))
ORDER BY object_name, instance_name, counter_name;" "$outfile" "-b -V 16"
}

fetch_sql_all() {
  local run_id="$1" vu="$2" phase="$3"
  mkdir -p "${RESULTS_DIR}/${run_id}"
  for f in waits io log perf; do
    ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -a \
      "src=${WIN_METRICS}\\${run_id}_vu${vu}_${phase}_${f}.csv dest=${RESULTS_DIR}/${run_id}/ flat=yes"
  done
}

write_local_meta() {
  local run_id="$1" vu="$2"
  mkdir -p "${RESULTS_DIR}/${run_id}"
  cat > "${RESULTS_DIR}/${run_id}/meta.txt" <<EOF
run_id=${run_id}
vu_scale=${vu}
utc_start=${RUN_UTC_START}
platform=windows
inv=${INV}
sql_group=${SQL_GROUP}
k6_group=${K6_GROUP}
diag=${DIAG}
diag_seconds=${DIAG_SECONDS}
db_name=${DB_NAME}
sql_user=${SQL_USER}
EOF
}

# ===== k6 + Endpoint (Linux, unchanged from RHEL version) =====

restart_endpoint() {
  echo "Restarting endpoint service..."
  ansible -i "$INV" "${EP_GROUP}" -m ansible.builtin.systemd -b -a \
    "name=benchtest state=restarted"
}

wait_endpoint_ready() {
  local max_attempts=15
  local attempt=1
  echo -n "Waiting for endpoint health "
  while [[ $attempt -le $max_attempts ]]; do
    if ansible -i "$INV" "${EP_GROUP}" -m ansible.builtin.uri -b -a \
      "url=http://localhost:5000/api/sessions/00000000-0000-0000-0000-000000000000/availability status_code=200,404,500" \
      >/dev/null 2>&1; then
      echo " OK (attempt $attempt)"
      return 0
    fi
    echo -n "."
    sleep 2
    attempt=$((attempt + 1))
  done
  echo " FAILED after $max_attempts attempts"
  return 1
}

run_k6_and_collect() {
  local run_id="$1" vu="$2"
  local remote_dir="/var/tmp/benchtest-k6/${run_id}/vu${vu}"
  local remote_log="${remote_dir}/k6_stdout.log"
  local remote_ver="${remote_dir}/k6_version.txt"
  local remote_sha="${remote_dir}/run_sh.sha256"
  local remote_art="${remote_dir}/k6_artifacts.tar.gz"
  local remote_status="${remote_dir}/k6_status.txt"

  set +e
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.shell -b -a "
set -euo pipefail
mkdir -p '$remote_dir'
START=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')

(cd /opt/k6 && (k6 version || true) > '$remote_ver' 2>&1)
(sha256sum /opt/k6/run.sh || true) > '$remote_sha' 2>&1

cd /opt/k6
set -o pipefail
VU_SCALE=$vu /opt/k6/run.sh main-exhaustion.js 2>&1 | tee '$remote_log'
rc=\${PIPESTATUS[0]}
echo \"k6_exit_code=\$rc\" > '$remote_status'

FILES_COUNT=\$(find /opt/k6 -maxdepth 3 -type f \\( -name '*.json' -o -name '*.html' -o -name '*.csv' -o -name '*.xml' -o -name '*.txt' \\) -newermt \"\$START\" | wc -l || true)
if [ \"\$FILES_COUNT\" -gt 0 ]; then
  find /opt/k6 -maxdepth 3 -type f \\( -name '*.json' -o -name '*.html' -o -name '*.csv' -o -name '*.xml' -o -name '*.txt' \\) -newermt \"\$START\" -print0 \
    | tar -czf '$remote_art' --null -T -
else
  : > '${remote_dir}/k6_artifacts.empty'
fi

exit \$rc
"
  local rc=$?
  set -e

  mkdir -p "${RESULTS_DIR}/${run_id}"
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_log dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_ver dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_sha dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_status dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_art dest=${RESULTS_DIR}/${run_id}/ flat=yes" 2>/dev/null || true

  return $rc
}

# ===== DIAG: OS-level diagnostics on Windows SQL host =====
# Replaces vmstat/iostat/biolatency with typeperf counters.
# Output: native typeperf CSV (PDH format) — same naming convention as RHEL.
#
# Collected counters:
#   cpu.csv    → Processor % User/Privileged/Idle, Context Switches/sec, Memory Available MB
#   diskio.csv → PhysicalDisk Reads/Writes per sec, Avg latency Read/Write, % Disk Time
#
# Note: biolatency (disk latency histogram) has no Windows equivalent.
#       Avg disk latency from typeperf covers the primary comparison use case.

start_diag_sql_host() {
  local run_id="$1" vu="$2"
  local d="${WIN_DIAG}\\${run_id}\\vu${vu}"

  win_sql "
\$d = '${d}'
New-Item -ItemType Directory -Force -Path \$d | Out-Null

# --- Diag meta ---
\$meta = @()
\$meta += \"diag_start_utc=\$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))\"
\$meta += \"platform=windows\"

# SQL Server PID
\$proc = Get-Process -Name sqlservr -ErrorAction SilentlyContinue | Select-Object -First 1
if (\$proc) {
  \$meta += \"sqlservr_pid=\$(\$proc.Id)\"
} else {
  \$meta += 'sqlservr_pid=not_found'
}

# --- CPU + Memory counters (equivalent to vmstat) ---
\$cpuCounters = @(
  '\\Processor(_Total)\\% User Time',
  '\\Processor(_Total)\\% Privileged Time',
  '\\Processor(_Total)\\% Idle Time',
  '\\System\\Context Switches/sec',
  '\\Memory\\Available MBytes'
)
\$cpuFile = Join-Path \$d 'cpu.csv'
\$cpuArgs = \$cpuCounters + @('-si', '1', '-sc', '${DIAG_SECONDS}', '-f', 'CSV', '-o', \$cpuFile)
\$cpuProc = Start-Process -FilePath 'typeperf' -ArgumentList \$cpuArgs -NoNewWindow -PassThru
\$meta += 'typeperf_cpu=started'

# --- Disk IO counters (equivalent to iostat) ---
\$diskCounters = @(
  '\\PhysicalDisk(*)\\Disk Reads/sec',
  '\\PhysicalDisk(*)\\Disk Writes/sec',
  '\\PhysicalDisk(*)\\Disk Read Bytes/sec',
  '\\PhysicalDisk(*)\\Disk Write Bytes/sec',
  '\\PhysicalDisk(*)\\Avg. Disk sec/Read',
  '\\PhysicalDisk(*)\\Avg. Disk sec/Write',
  '\\PhysicalDisk(*)\\% Disk Time'
)
\$diskFile = Join-Path \$d 'diskio.csv'
\$diskArgs = \$diskCounters + @('-si', '1', '-sc', '${DIAG_SECONDS}', '-f', 'CSV', '-o', \$diskFile)
\$diskProc = Start-Process -FilePath 'typeperf' -ArgumentList \$diskArgs -NoNewWindow -PassThru
\$meta += 'typeperf_diskio=started'

# biolatency not available on Windows
\$meta += 'biolatency=not_available_windows'

# Write meta (pre-wait)
\$meta | Out-File -FilePath (Join-Path \$d 'diag_meta.txt') -Encoding utf8

# Wait for both typeperf processes to finish
\$cpuProc  | Wait-Process -Timeout $((DIAG_SECONDS + 30)) -ErrorAction SilentlyContinue
\$diskProc | Wait-Process -Timeout $((DIAG_SECONDS + 30)) -ErrorAction SilentlyContinue

# Append end timestamp
Add-Content -Path (Join-Path \$d 'diag_meta.txt') -Value \"diag_end_utc=\$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))\"
"
}

fetch_diag_sql_host() {
  local run_id="$1" vu="$2"
  local d="${WIN_DIAG}\\${run_id}\\vu${vu}"

  mkdir -p "${RESULTS_DIR}/${run_id}"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -a \
    "src=${d}\\diag_meta.txt dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -a \
    "src=${d}\\cpu.csv dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -a \
    "src=${d}\\diskio.csv dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
}

# ===== Main =====
ensure_sql_dirs
ensure_k6_dirs

echo "== BenchTest runbook [Windows SQL] starting (UTC $(ts_utc)) =="
echo "Inventory: $INV"
echo "Scales: ${SCALES_ARR[*]}"
echo "DIAG: $DIAG (seconds=$DIAG_SECONDS)"
echo

overall_fail=0

for vu in "${SCALES_ARR[@]}"; do
  run_id="$(uuidgen)"
  RUN_UTC_START="$(ts_utc)"

  echo "=== RUN_ID=$run_id  VU_SCALE=$vu  START=$RUN_UTC_START ==="
  write_local_meta "$run_id" "$vu"

  reset_db
  clear_waits

  restart_endpoint
  wait_endpoint_ready

  snap_waits "$run_id" "$vu" "begin"
  snap_io    "$run_id" "$vu" "begin"
  snap_log   "$run_id" "$vu" "begin"
  snap_perf  "$run_id" "$vu" "begin"
  fetch_sql_all "$run_id" "$vu" "begin"

  if [[ "$DIAG" == "1" ]]; then
    echo "DIAG enabled: collecting typeperf on Windows SQL host for ${DIAG_SECONDS}s..."
    start_diag_sql_host "$run_id" "$vu" || true
  fi

  if run_k6_and_collect "$run_id" "$vu"; then
    echo "k6: OK"
  else
    rc=$?
    echo "k6: FAILED (exit=$rc) — continuing to END snapshots"
    overall_fail=1
  fi

  if [[ "$DIAG" == "1" ]]; then
    fetch_diag_sql_host "$run_id" "$vu" || true
  fi

  snap_waits "$run_id" "$vu" "end"
  snap_io    "$run_id" "$vu" "end"
  snap_log   "$run_id" "$vu" "end"
  snap_perf  "$run_id" "$vu" "end"
  fetch_sql_all "$run_id" "$vu" "end"

  echo "=== DONE RUN_ID=$run_id  END=$(ts_utc) ==="
  echo
done

echo "All runs complete. Results in ./${RESULTS_DIR}/<RUN_ID>/"

if [[ "$overall_fail" -ne 0 ]]; then
  echo "One or more k6 runs failed (see k6_status.txt / k6_stdout.log)."
  exit 1
fi