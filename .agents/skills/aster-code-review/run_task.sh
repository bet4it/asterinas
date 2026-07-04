#!/usr/bin/env bash

# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: run_task.sh <check|test|smoke|benchmark>

Environment:
  ACR_AGENT_PROFILE=<name>   required for smoke and benchmark
  PROBLEMS="0002 0006"       optional problem selectors
  SMOKE_PROBLEMS="..."       smoke subset, default: 0002 0006
  MIN_RECALL=<0..100>        benchmark recall gate, default: 100
  KEEP=<dir>|1               keep benchmark reviews for inspection
EOF
    exit 2
}

run_tests() {
    local fail=0
    local suite

    shopt -s nullglob
    for suite in "$here"/tests/test_*.sh; do
        "$suite" || fail=1
    done
    shopt -u nullglob

    echo "----"
    if [ "$fail" -eq 0 ]; then
        echo "ALL SUITES PASSED"
    else
        echo "SOME SUITES FAILED"
    fi
    exit "$fail"
}

[ "$#" -eq 1 ] || usage

case "$1" in
    check)
        "$here/benchmark/validate_problem_yaml.sh"
        ;;
    test)
        run_tests
        ;;
    smoke)
        : "${ACR_AGENT_PROFILE:?ACR_AGENT_PROFILE is required for smoke}"
        ACR_PROFILE_VARIANT=smoke \
            MIN_RECALL=0 \
            PROBLEMS="${PROBLEMS:-${SMOKE_PROBLEMS:-0002 0006}}" \
            KEEP_REVIEWS="${KEEP:-}" \
            "$here/benchmark/run.sh"
        ;;
    benchmark)
        : "${ACR_AGENT_PROFILE:?ACR_AGENT_PROFILE is required for benchmark}"
        MIN_RECALL="${MIN_RECALL:-100}" \
            PROBLEMS="${PROBLEMS:-}" \
            KEEP_REVIEWS="${KEEP:-}" \
            "$here/benchmark/run.sh"
        ;;
    *)
        usage
        ;;
esac
