#!/bin/bash
#
# Copyright 2025 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -e

#
# Script to run kuttl tests, with support for parallel execution.
#
# Usage:
#   run-kuttl.sh --kuttl-dir <dir> --kuttl-conf <conf> --namespace <ns> [--parallel <n>] [--kuttl-args <args>]
#
# Environment variables (alternative to command-line args):
#   KUTTL_DIR      - The kuttl test directory
#   KUTTL_CONF     - The kuttl config file
#   NAMESPACE      - The Kubernetes namespace (base namespace for parallel runs)
#   KUTTL_ARGS     - Additional arguments to pass to kubectl-kuttl
#   PARALLEL       - Number of parallel executions (default: 1)
#
# When --parallel is greater than 1, the script will:
#   1. Find all test directories in KUTTL_DIR
#   2. Split them evenly into N groups
#   3. Run kubectl-kuttl with --test flags for each test in the group
#   4. Use namespaces: NAMESPACE, NAMESPACE2, NAMESPACE3, etc.
#

function usage {
    echo "Usage: $0 --kuttl-dir <dir> --kuttl-conf <conf> --namespace <ns> [--parallel <n>] [--kuttl-args <args>]"
    echo ""
    echo "Options:"
    echo "  --kuttl-dir   The kuttl test directory (required)"
    echo "  --kuttl-conf  The kuttl config file (required)"
    echo "  --namespace   The Kubernetes namespace (required)"
    echo "  --parallel    Number of parallel executions (default: 1)"
    echo "  --kuttl-args  Additional arguments to pass to kubectl-kuttl (optional)"
    echo "  --help        Show this help message"
    echo ""
    echo "Environment variables can also be used:"
    echo "  KUTTL_DIR, KUTTL_CONF, NAMESPACE, KUTTL_ARGS, PARALLEL"
    exit 1
}

# Default values
PARALLEL="${PARALLEL:-1}"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --kuttl-dir)
            KUTTL_DIR="$2"
            shift 2
            ;;
        --kuttl-conf)
            KUTTL_CONF="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
            ;;
        --kuttl-args)
            KUTTL_ARGS="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "${KUTTL_DIR}" ]]; then
    echo "Error: KUTTL_DIR is required (use --kuttl-dir or set KUTTL_DIR env var)"
    usage
fi

if [[ -z "${KUTTL_CONF}" ]]; then
    echo "Error: KUTTL_CONF is required (use --kuttl-conf or set KUTTL_CONF env var)"
    usage
fi

if [[ -z "${NAMESPACE}" ]]; then
    echo "Error: NAMESPACE is required (use --namespace or set NAMESPACE env var)"
    usage
fi

if ! [[ "${PARALLEL}" =~ ^[0-9]+$ ]] || [[ "${PARALLEL}" -lt 1 ]]; then
    echo "Error: PARALLEL must be a positive integer"
    usage
fi

# Export KUTTL_DIR for any tests that may reference it
export KUTTL_DIR

echo "Running kuttl tests..."
echo "  KUTTL_DIR:  ${KUTTL_DIR}"
echo "  KUTTL_CONF: ${KUTTL_CONF}"
echo "  NAMESPACE:  ${NAMESPACE}"
echo "  PARALLEL:   ${PARALLEL}"
echo "  KUTTL_ARGS: ${KUTTL_ARGS:-<none>}"

# Function to run kuttl with specific tests
run_kuttl_with_tests() {
    local test_dir="$1"
    local namespace="$2"
    local kuttl_conf="$3"
    local kuttl_args="$4"
    shift 4
    local test_args=("$@")

    echo "Starting kuttl tests in namespace ${namespace}"
    echo "  Tests: ${test_args[*]}"

    # Build the --test arguments
    local test_flags=""
    for test_name in "${test_args[@]}"; do
        test_flags="${test_flags} --test ${test_name}"
    done

    # shellcheck disable=SC2086
    KEYSTONE_KUTTL_DIR=${test_dir} kubectl-kuttl test --config "${kuttl_conf}" "${test_dir}" --namespace "${namespace}" ${test_flags} ${kuttl_args}
}

# Function to run a single kuttl test (no filtering)
run_single_kuttl() {
    local test_dir="$1"
    local namespace="$2"
    local kuttl_conf="$3"
    local kuttl_args="$4"

    echo "Starting kuttl tests in namespace ${namespace} with test dir ${test_dir}"
    # shellcheck disable=SC2086
    KEYSTONE_KUTTL_DIR=${test_dir} kubectl-kuttl test --config "${kuttl_conf}" "${test_dir}" --namespace "${namespace}" ${kuttl_args}
}

# If parallel is 1, just run the single kuttl command
if [[ "${PARALLEL}" -eq 1 ]]; then
    run_single_kuttl "${KUTTL_DIR}" "${NAMESPACE}" "${KUTTL_CONF}" "${KUTTL_ARGS}"
    exit 0
fi

# Parallel execution: find all test directories
echo "Discovering test directories in ${KUTTL_DIR}..."

# Find all test directories, excluding "common" (which is shared resources, not a test)
mapfile -t TEST_DIRS < <(find "${KUTTL_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name "common" | sort)

# Extract just the test names (directory basenames)
declare -a TEST_NAMES
for dir in "${TEST_DIRS[@]}"; do
    TEST_NAMES+=("$(basename "${dir}")")
done

NUM_TESTS=${#TEST_NAMES[@]}
echo "Found ${NUM_TESTS} test directories (excluding 'common')"

if [[ ${NUM_TESTS} -eq 0 ]]; then
    echo "Error: No test directories found in ${KUTTL_DIR}"
    exit 1
fi

# Adjust parallel count if we have fewer tests than requested parallel runs
if [[ ${PARALLEL} -gt ${NUM_TESTS} ]]; then
    echo "Adjusting parallel count from ${PARALLEL} to ${NUM_TESTS} (number of tests)"
    PARALLEL=${NUM_TESTS}
fi

# Calculate how to split tests across parallel runs
TESTS_PER_GROUP=$((NUM_TESTS / PARALLEL))
REMAINDER=$((NUM_TESTS % PARALLEL))

echo "Splitting ${NUM_TESTS} tests into ${PARALLEL} groups (${TESTS_PER_GROUP} tests per group, ${REMAINDER} groups get an extra test)"

# Build test groups
declare -a GROUP_NAMESPACES
declare -a GROUP_TESTS  # Space-separated list of test names for each group

current_test=0
for ((group=0; group<PARALLEL; group++)); do
    # Determine namespace for this group
    if [[ ${group} -eq 0 ]]; then
        GROUP_NAMESPACES[${group}]="${NAMESPACE}"
    else
        GROUP_NAMESPACES[${group}]="${NAMESPACE}$((group + 1))"
    fi

    # Calculate number of tests for this group
    # First REMAINDER groups get an extra test
    if [[ ${group} -lt ${REMAINDER} ]]; then
        tests_in_this_group=$((TESTS_PER_GROUP + 1))
    else
        tests_in_this_group=${TESTS_PER_GROUP}
    fi

    # Collect test names for this group
    group_test_list=""
    for ((i=0; i<tests_in_this_group; i++)); do
        if [[ ${current_test} -lt ${NUM_TESTS} ]]; then
            if [[ -n "${group_test_list}" ]]; then
                group_test_list="${group_test_list} ${TEST_NAMES[${current_test}]}"
            else
                group_test_list="${TEST_NAMES[${current_test}]}"
            fi
            current_test=$((current_test + 1))
        fi
    done
    GROUP_TESTS[${group}]="${group_test_list}"

    echo "Group $((group + 1)): ${tests_in_this_group} tests (namespace: ${GROUP_NAMESPACES[${group}]})"
    echo "  Tests: ${GROUP_TESTS[${group}]}"
done

# Run all groups in parallel
echo ""
echo "Starting ${PARALLEL} parallel kuttl test runs..."
declare -a PIDS
declare -a EXIT_CODES

for ((group=0; group<PARALLEL; group++)); do
    # Convert space-separated test list to array
    # shellcheck disable=SC2206
    test_array=(${GROUP_TESTS[${group}]})
    
    (
        run_kuttl_with_tests "${KUTTL_DIR}" "${GROUP_NAMESPACES[${group}]}" "${KUTTL_CONF}" "${KUTTL_ARGS}" "${test_array[@]}"
    ) &
    PIDS[${group}]=$!
    echo "Started group $((group + 1)) with PID ${PIDS[${group}]}"
done

# Wait for all parallel runs to complete and collect exit codes
echo ""
echo "Waiting for all parallel runs to complete..."
FAILED=0
for ((group=0; group<PARALLEL; group++)); do
    if wait "${PIDS[${group}]}"; then
        EXIT_CODES[${group}]=0
        echo "Group $((group + 1)) (PID ${PIDS[${group}]}) completed successfully"
    else
        EXIT_CODES[${group}]=$?
        echo "Group $((group + 1)) (PID ${PIDS[${group}]}) failed with exit code ${EXIT_CODES[${group}]}"
        FAILED=1
    fi
done

# Summary
echo ""
echo "=== Parallel Kuttl Test Summary ==="
for ((group=0; group<PARALLEL; group++)); do
    status="SUCCESS"
    if [[ ${EXIT_CODES[${group}]} -ne 0 ]]; then
        status="FAILED (exit code: ${EXIT_CODES[${group}]})"
    fi
    echo "  Group $((group + 1)) [${GROUP_NAMESPACES[${group}]}]: ${status}"
    echo "    Tests: ${GROUP_TESTS[${group}]}"
done

if [[ ${FAILED} -eq 1 ]]; then
    echo ""
    echo "One or more parallel test runs failed!"
    exit 1
fi

echo ""
echo "All parallel test runs completed successfully!"
exit 0
