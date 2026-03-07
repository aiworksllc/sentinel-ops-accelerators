#!/usr/bin/env bash
set -euo pipefail

#
# run-all.sh — Run all 35 Sentinel-Ops showcase simulations
#
# Usage:
#   ./run-all.sh                              # Run all themes
#   ./run-all.sh --theme 01-financial-services # Run one theme
#   ./run-all.sh --dry-run                     # Show what would run
#

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SHOWCASE_DIR="${REPO_DIR}/themes"
SOE_API="${SOE_API_URL:-}"
THEME_FILTER=""
DRY_RUN=false
PASSED=0
FAILED=0
SKIPPED=0

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --theme) THEME_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --api) SOE_API="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "${SOE_API}" ]]; then
  echo "ERROR: SOE_API_URL not set."
  echo "  export SOE_API_URL=https://your-stack.us-east-1.elb.amazonaws.com"
  echo "  Or pass: ./run-all.sh --api <url>"
  exit 1
fi

echo "========================================"
echo "Sentinel-Ops Showcase Runner"
echo "API: ${SOE_API}"
echo "========================================"
echo ""

# Check API is up
if ! curl -sf "${SOE_API}/v1/health" > /dev/null 2>&1; then
  echo "ERROR: SOE API not reachable at ${SOE_API}"
  echo "Check your SOE_API_URL or pass --api <url>"
  exit 1
fi

# Find all simulation files
for theme_dir in "${SHOWCASE_DIR}"/*/; do
  theme=$(basename "${theme_dir}")

  # Skip non-theme directories
  [[ -d "${theme_dir}/simulations" ]] || continue

  # Apply theme filter
  if [[ -n "${THEME_FILTER}" && "${theme}" != "${THEME_FILTER}" ]]; then
    continue
  fi

  echo "── Theme: ${theme} ──"

  for sim_file in "${theme_dir}"/simulations/simulate-*.json; do
    [[ -f "${sim_file}" ]] || continue

    sim_name=$(basename "${sim_file}" .json)
    sim_num="${sim_name#simulate-}"
    expected_file="${theme_dir}/expected-output/expected-${sim_num}.json"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "  [DRY-RUN] ${sim_name}"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Run simulation
    printf "  %-20s " "${sim_name}"
    response=$(curl -sf -X POST "${SOE_API}/v1/simulate" \
      -H "Content-Type: application/json" \
      -d @"${sim_file}" 2>&1) || {
      echo "FAIL (API error)"
      FAILED=$((FAILED + 1))
      continue
    }

    # Compare with expected output (if exists)
    if [[ -f "${expected_file}" ]]; then
      # Extract decision counts from response
      actual_allowed=$(echo "${response}" | jq '[.results[] | select(.decision == "ALLOW")] | length' 2>/dev/null || echo "?")
      actual_denied=$(echo "${response}" | jq '[.results[] | select(.decision == "DENY")] | length' 2>/dev/null || echo "?")
      expected_allowed=$(jq '.summary.allowed // 0' "${expected_file}" 2>/dev/null || echo "?")
      expected_denied=$(jq '.summary.denied // 0' "${expected_file}" 2>/dev/null || echo "?")

      if [[ "${actual_allowed}" == "${expected_allowed}" && "${actual_denied}" == "${expected_denied}" ]]; then
        echo "PASS (${actual_allowed} allowed, ${actual_denied} denied)"
        PASSED=$((PASSED + 1))
      else
        echo "DIFF (got ${actual_allowed}/${actual_denied}, expected ${expected_allowed}/${expected_denied})"
        FAILED=$((FAILED + 1))
      fi
    else
      echo "PASS (no expected output to compare)"
      PASSED=$((PASSED + 1))
    fi
  done

  echo ""
done

# Summary
echo "========================================"
echo "Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "========================================"

[[ ${FAILED} -eq 0 ]] && exit 0 || exit 1
