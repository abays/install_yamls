#!/bin/bash
#
# Unified KUTTL test runner that handles both serial and parallel execution.
#
# Usage:
#   kuttl-runner.sh <SERVICE> <KUTTL_DIR> <NAMESPACE_BASE> <PARALLEL_COUNT> <KUTTL_CONF>
#
# Arguments:
#   SERVICE         - Service name (e.g. "keystone"). Used to construct make
#                     targets: ${SERVICE}_kuttl_prep, ${SERVICE}_kuttl_run,
#                     ${SERVICE}_kuttl_deploy_cleanup, ${SERVICE}_kuttl_cleanup.
#   KUTTL_DIR       - Path to the test directory containing test subdirectories.
#   NAMESPACE_BASE  - Base namespace name (e.g. "keystone-kuttl-tests").
#   PARALLEL_COUNT  - Number of parallel workers. Defaults to 1 (serial).
#   KUTTL_CONF      - Path to the kuttl-test.yaml config file. In parallel mode,
#                     per-worker copies are generated with updated namespace and
#                     reportName fields.
#
# In serial mode (PARALLEL_COUNT <= 1), runs prep/run/cleanup sequentially in
# a single namespace -- functionally identical to the traditional make target.
#
# In parallel mode (PARALLEL_COUNT > 1), splits test subdirectories across N
# workers via kuttl's --test regex filter, runs prep per namespace, executes
# tests in parallel, then cleans up each namespace.

set -euo pipefail

declare -a pids=()
cleanup_bg() {
    for pid in "${pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            pkill -P "${pid}" 2>/dev/null || true
            kill "${pid}" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
}
trap cleanup_bg EXIT

SERVICE="${1:?SERVICE is required}"
KUTTL_DIR="${2:?KUTTL_DIR is required}"
NAMESPACE_BASE="${3:?NAMESPACE_BASE is required}"
N="${4:-1}"
KUTTL_CONF="${5:?KUTTL_CONF is required}"
SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]' '[:upper:]')"
KUTTL_CONF_VAR="${SERVICE_UPPER}_KUTTL_CONF"

if [[ "$N" -le 0 ]]; then
    N=1
fi

if [[ "$N" -eq 1 ]]; then
    export NAMESPACE="${NAMESPACE_BASE}"
    make "${SERVICE}_kuttl_prep"
    make wait
    make "${SERVICE}_kuttl_run"
    make "${SERVICE}_kuttl_cleanup"
    exit 0
fi

# -- Parallel path --

# Prep the first namespace first -- this clones the operator repo and creates
# the test directory, which we need to enumerate before prepping the rest.
echo "=== Preparing namespace ${NAMESPACE_BASE}-0 ==="
NAMESPACE="${NAMESPACE_BASE}-0" STORAGE_ID="worker-0" make "${SERVICE}_kuttl_prep"
NAMESPACE="${NAMESPACE_BASE}-0" STORAGE_ID="worker-0" make wait

tests=()
for d in "${KUTTL_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    tests+=("$(basename "$d")")
done

num_tests=${#tests[@]}
if [[ "$num_tests" -eq 0 ]]; then
    echo "ERROR: no test subdirectories found in ${KUTTL_DIR}" >&2
    exit 1
fi

if [[ "$N" -gt "$num_tests" ]]; then
    echo "Reducing worker count from ${N} to ${num_tests} (number of tests)"
    N=$num_tests
fi

# Round-robin assign tests to workers
declare -a worker_tests
for i in $(seq 0 $((N - 1))); do
    worker_tests[$i]=""
done

for i in "${!tests[@]}"; do
    bucket=$((i % N))
    if [[ -n "${worker_tests[$bucket]}" ]]; then
        worker_tests[$bucket]="${worker_tests[$bucket]}|${tests[$i]}"
    else
        worker_tests[$bucket]="${tests[$i]}"
    fi
done

echo "=== Parallel KUTTL run: ${num_tests} tests across ${N} workers ==="
for i in $(seq 0 $((N - 1))); do
    echo "  Worker ${i}: ${worker_tests[$i]}"
done

# Prep remaining namespaces
for i in $(seq 1 $((N - 1))); do
    ns="${NAMESPACE_BASE}-${i}"
    echo "=== Preparing namespace ${ns} ==="
    NAMESPACE="${ns}" STORAGE_ID="worker-${i}" make "${SERVICE}_kuttl_prep"
    NAMESPACE="${ns}" STORAGE_ID="worker-${i}" make wait
done

# Generate per-worker kuttl config files with unique namespace and reportName
conf_dir="$(dirname "${KUTTL_CONF}")"
declare -a worker_conf
for i in $(seq 0 $((N - 1))); do
    ns="${NAMESPACE_BASE}-${i}"
    wconf="${conf_dir}/kuttl-test-worker-${i}.yaml"
    sed -e "s|${NAMESPACE_BASE}|${ns}|g" \
        -e "s|^reportName:.*|reportName: kuttl-report-${SERVICE}-worker-${i}|" \
        "${KUTTL_CONF}" > "${wconf}"
    worker_conf[$i]="${wconf}"
done

# Run tests in parallel
log_dir="${ARTIFACTS_DIR:-/tmp}/kuttl-parallel-logs"
mkdir -p "${log_dir}"

declare -a pids
declare -a worker_ns
declare -a log_files

for i in $(seq 0 $((N - 1))); do
    ns="${NAMESPACE_BASE}-${i}"
    regex="^(${worker_tests[$i]})"
    log_file="${log_dir}/worker-${i}.log"
    worker_ns[$i]="$ns"
    log_files[$i]="${log_file}"
    : > "${log_file}"

    echo "=== Starting worker ${i} in namespace ${ns} (log: ${log_file}) ==="
    (
        env NAMESPACE="${ns}" STORAGE_ID="worker-${i}" \
            "${KUTTL_CONF_VAR}=${worker_conf[$i]}" KUTTL_ARGS="--test '${regex}'" \
            KUTTL_TEST_FILTER="${regex}" \
            make "${SERVICE}_kuttl_run" >> "${log_file}" 2>&1
    ) &
    pids[$i]=$!
done

# Wait for all workers and collect exit codes, streaming logs in the meantime
declare -a results
any_failed=0
workers_done=0

while [[ "$workers_done" -lt "$N" ]]; do
    for i in $(seq 0 $((N - 1))); do
        [[ -n "${results[$i]+set}" ]] && continue
        if ! kill -0 "${pids[$i]}" 2>/dev/null; then
            set +e
            wait "${pids[$i]}"
            results[$i]=$?
            set -e
            workers_done=$((workers_done + 1))
            if [[ "${results[$i]}" -ne 0 ]]; then
                any_failed=1
                echo ""
                echo "=== Worker ${i} FAILED (exit ${results[$i]}) ==="
            else
                echo ""
                echo "=== Worker ${i} PASSED ==="
            fi
        fi
    done
    # Print new log output
    for i in $(seq 0 $((N - 1))); do
        local_lines=$(wc -l < "${log_files[$i]}" 2>/dev/null || echo 0)
        prev_var="printed_lines_${i}"
        prev=${!prev_var:-0}
        if [[ "$local_lines" -gt "$prev" ]]; then
            tail -n +"$((prev + 1))" "${log_files[$i]}" 2>/dev/null
            eval "printed_lines_${i}=${local_lines}"
        fi
    done
    [[ "$workers_done" -lt "$N" ]] && sleep 2
done

# Cleanup timeout (seconds) -- prevents infinite hangs on stuck finalizers
CLEANUP_TIMEOUT="${KUTTL_CLEANUP_TIMEOUT:-600}"

# Phase 1: remove CRs from all namespaces (operators stay running)
for i in $(seq 0 $((N - 1))); do
    ns="${worker_ns[$i]}"
    echo "=== Cleaning up CRs in namespace ${ns} ==="
    timeout "${CLEANUP_TIMEOUT}" \
        env NAMESPACE="${ns}" STORAGE_ID="worker-${i}" make "${SERVICE}_kuttl_deploy_cleanup" || true
done

# Phase 2: full cleanup including operators (CR re-cleanup is idempotent)
echo "=== Final cleanup (including operators) ==="
for i in $(seq 0 $((N - 1))); do
    timeout "${CLEANUP_TIMEOUT}" \
        env NAMESPACE="${worker_ns[$i]}" STORAGE_ID="worker-${i}" make "${SERVICE}_kuttl_cleanup" || true
done

# Print summary
echo ""
echo "=== KUTTL Parallel Run Summary ==="
for i in $(seq 0 $((N - 1))); do
    status="PASS"
    if [[ "${results[$i]}" -ne 0 ]]; then
        status="FAIL (exit ${results[$i]})"
    fi
    echo "  Worker ${i} [${worker_ns[$i]}]: ${status}"
    echo "    Tests: ${worker_tests[$i]}"
done

if [[ "$any_failed" -ne 0 ]]; then
    echo ""
    echo "FAILED: one or more workers failed"
    exit 1
fi

echo ""
echo "All workers passed"
