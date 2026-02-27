#!/usr/bin/env bash
set -euo pipefail

# ===== BenchTest Runbook (RHEL SQL host) =====
# Runs: reset -> clear waits -> BEGIN snapshots -> k6 -> END snapshots
# Also collects: k6 stdout log + version + run.sh sha256 + artifacts tarball
# Optional DIAG=1: perf trace fdatasync/fsync + biolatency/iostat on SQL host

# --- Config (override via env if you want) ---
INV="${INV:-inventory.ini}"
SQL_GROUP="${SQL_GROUP:-sql}"
K6_GROUP="${K6_GROUP:-k6}"
EP_GROUP="${EP_GROUP:-endpoint}"

DB_NAME="${DB_NAME:-InstantPaymentBench}"
SQL_USER="${SQL_USER:-sa}"
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"

RESET_PLAYBOOK="${RESET_PLAYBOOK:-playbooks/deploy-sql-rhel.yml}"

SCALES_DEFAULT=(1 3 9)
if [[ -n "${SCALES:-}" ]]; then
  # Example: SCALES="1 3 6 9"
  read -r -a SCALES_ARR <<< "${SCALES}"
else
  SCALES_ARR=("${SCALES_DEFAULT[@]}")
fi

DIAG="${DIAG:-0}"
DIAG_SECONDS="${DIAG_SECONDS:-120}"

RESULTS_DIR="${RESULTS_DIR:-results}"

# ===== Helpers =====
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
require ansible
require ansible-playbook
require uuidgen

ts_utc() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

ensure_sql_dirs() {
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    'mkdir -p /var/tmp/benchtest-metrics /var/tmp/benchtest-diag && chmod 0777 /var/tmp/benchtest-metrics /var/tmp/benchtest-diag'
}

ensure_k6_dirs() {
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.shell -b -a \
    'mkdir -p /var/tmp/benchtest-k6 && chmod 0777 /var/tmp/benchtest-k6'
}

reset_db() {
  ansible-playbook -i "$INV" "$RESET_PLAYBOOK" --tags reset
}

clear_waits() {
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    "${SQLCMD} -S localhost -U ${SQL_USER} -P \"{{ sql_auth_password }}\" -C -Q \"DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);\" -b -V 16"
}

snap_waits() {
  local run_id="$1" vu="$2" phase="$3"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    "${SQLCMD} -S localhost -U ${SQL_USER} -P \"{{ sql_auth_password }}\" -C -W -s \",\" -Q \"SET NOCOUNT ON;
SELECT SYSUTCDATETIME() AS captured_at_utc, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('WRITELOG','IO_COMPLETION','PAGEIOLATCH_SH','PAGEIOLATCH_EX','PAGEIOLATCH_UP',
'LCK_M_X','LCK_M_U','LCK_M_S','LCK_M_IS','LCK_M_IX','LCK_M_SCH_S','LCK_M_SCH_M',
'PAGELATCH_EX','PAGELATCH_SH','PAGELATCH_UP','SOS_SCHEDULER_YIELD')
ORDER BY wait_time_ms DESC;\" -o /var/tmp/benchtest-metrics/${run_id}_vu${vu}_${phase}_waits.csv -b -V 16"
}

snap_io() {
  local run_id="$1" vu="$2" phase="$3"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    "${SQLCMD} -S localhost -U ${SQL_USER} -P \"{{ sql_auth_password }}\" -C -W -s \",\" -Q \"SET NOCOUNT ON;
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
ORDER BY database_name,mf.type_desc,vfs.file_id;\" -o /var/tmp/benchtest-metrics/${run_id}_vu${vu}_${phase}_io.csv -b -V 16"
}

snap_log() {
  local run_id="$1" vu="$2" phase="$3"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    "${SQLCMD} -S localhost -U ${SQL_USER} -P \"{{ sql_auth_password }}\" -C -W -s \",\" -Q \"SET NOCOUNT ON;
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
FROM sys.dm_db_log_stats(DB_ID(N'${DB_NAME}')) AS ls;\" -o /var/tmp/benchtest-metrics/${run_id}_vu${vu}_${phase}_log.csv -b"
}



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

snap_perf() {
  local run_id="$1" vu="$2" phase="$3"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a \
    "${SQLCMD} -S localhost -U ${SQL_USER} -P \"{{ sql_auth_password }}\" -C -W -s \",\" -Q \"SET NOCOUNT ON;
SELECT SYSUTCDATETIME() AS captured_at_utc, object_name, counter_name, instance_name, cntr_value, cntr_type
FROM sys.dm_os_performance_counters
WHERE
  (object_name LIKE '%:Databases%' AND instance_name IN ('${DB_NAME}','tempdb') AND counter_name IN
    ('Log Flush Wait Time','Log Flush Waits/sec','Log Flushes/sec','Log Bytes Flushed/sec','Transactions/sec'))
  OR
  (object_name LIKE '%:SQL Statistics%' AND counter_name IN
    ('Batch Requests/sec','SQL Compilations/sec','SQL Re-Compilations/sec'))
  OR
  (object_name LIKE '%:Locks%' AND instance_name IN ('_Total','${DB_NAME}') AND counter_name IN
    ('Lock Waits/sec','Lock Wait Time (ms)','Number of Deadlocks/sec'))
ORDER BY object_name, instance_name, counter_name;\" -o /var/tmp/benchtest-metrics/${run_id}_vu${vu}_${phase}_perf.csv -b -V 16"
}

fetch_sql_all() {
  local run_id="$1" vu="$2" phase="$3"
  mkdir -p "${RESULTS_DIR}/${run_id}"
  for f in waits io log perf; do
    ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -b -a \
      "src=/var/tmp/benchtest-metrics/${run_id}_vu${vu}_${phase}_${f}.csv dest=${RESULTS_DIR}/${run_id}/ flat=yes"
  done
}

write_local_meta() {
  local run_id="$1" vu="$2"
  mkdir -p "${RESULTS_DIR}/${run_id}"
  cat > "${RESULTS_DIR}/${run_id}/meta.txt" <<EOF
run_id=${run_id}
vu_scale=${vu}
utc_start=${RUN_UTC_START}
inv=${INV}
sql_group=${SQL_GROUP}
k6_group=${K6_GROUP}
diag=${DIAG}
diag_seconds=${DIAG_SECONDS}
db_name=${DB_NAME}
sql_user=${SQL_USER}
EOF
}

run_k6_and_collect() {
  local run_id="$1" vu="$2"
  local remote_dir="/var/tmp/benchtest-k6/${run_id}/vu${vu}"
  local remote_log="${remote_dir}/k6_stdout.log"
  local remote_ver="${remote_dir}/k6_version.txt"
  local remote_sha="${remote_dir}/run_sh.sha256"
  local remote_art="${remote_dir}/k6_artifacts.tar.gz"
  local remote_status="${remote_dir}/k6_status.txt"

  # Run k6 but do NOT abort this runbook if k6 exits non-zero; we still want END snapshots.
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

  # Optional artifact tarball
  ansible -i "$INV" "$K6_GROUP" -m ansible.builtin.fetch -b -a \
    "src=$remote_art dest=${RESULTS_DIR}/${run_id}/ flat=yes" 2>/dev/null || true

  return $rc
}

start_diag_sql_host() {
  local run_id="$1" vu="$2"
  local d="/var/tmp/benchtest-diag/${run_id}/vu${vu}"

  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.shell -b -a "
set -euo pipefail
mkdir -p '$d' && chmod 0777 '$d'
echo \"diag_start_utc=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')\" > '$d/diag_meta.txt'

PID=\$(pgrep -n sqlservr || true)
if [ -z \"\$PID\" ]; then
  echo 'sqlservr_pid=not_found' >> '$d/diag_meta.txt'
else
  echo \"sqlservr_pid=\$PID\" >> '$d/diag_meta.txt'
fi

# vmstat — CPU, memory, swap, context switches (near-zero overhead)
timeout ${DIAG_SECONDS} vmstat 1 ${DIAG_SECONDS} > '$d/vmstat.txt' 2>&1 &
echo 'vmstat=started' >> '$d/diag_meta.txt'

# iostat — per-device IO metrics (near-zero overhead, always collected)
timeout ${DIAG_SECONDS} iostat -x 1 ${DIAG_SECONDS} > '$d/iostat.txt' 2>&1 &
echo 'iostat=started' >> '$d/diag_meta.txt'

# biolatency — block-layer latency histogram (eBPF, low overhead)
BIO=''
if [ -x /usr/share/bcc/tools/biolatency ]; then BIO=/usr/share/bcc/tools/biolatency; fi
if command -v biolatency >/dev/null 2>&1; then BIO=\$(command -v biolatency); fi

if [ -n \"\$BIO\" ]; then
  timeout ${DIAG_SECONDS} \"\$BIO\" 1 ${DIAG_SECONDS} > '$d/biolatency.txt' 2>&1 &
  echo 'biolatency=started' >> '$d/diag_meta.txt'
else
  echo 'biolatency=missing' >> '$d/diag_meta.txt'
fi

wait || true
echo \"diag_end_utc=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')\" >> '$d/diag_meta.txt'
"
}

fetch_diag_sql_host() {
  local run_id="$1" vu="$2"
  local d="/var/tmp/benchtest-diag/${run_id}/vu${vu}"

  mkdir -p "${RESULTS_DIR}/${run_id}"
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -b -a "src=$d/diag_meta.txt dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -b -a "src=$d/vmstat.txt dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -b -a "src=$d/iostat.txt dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
  ansible -i "$INV" "$SQL_GROUP" -m ansible.builtin.fetch -b -a "src=$d/biolatency.txt dest=${RESULTS_DIR}/${run_id}/ flat=yes" || true
}

# ===== Main =====
ensure_sql_dirs
ensure_k6_dirs

echo "== BenchTest runbook starting (UTC $(ts_utc)) =="
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
    echo "DIAG enabled: collecting perf/biolatency on SQL host for ${DIAG_SECONDS}s..."
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