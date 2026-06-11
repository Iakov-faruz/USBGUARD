#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Test Runner
# Runs all unit tests with comprehensive coverage
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${COLOR_BOLD}║    USBGuard Test Suite Runner                ║${COLOR_RESET}"
echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
echo ""

# Ensure we run from project root
cd "$PROJECT_ROOT"

# Detect or create Python virtual environment
VENV_DIR="${PROJECT_ROOT}/web/venv"

# If venv directory exists but lacks pip, it's a broken/partial venv
if [[ -d "$VENV_DIR" && ! -f "${VENV_DIR}/bin/pip" ]]; then
    echo -e "${COLOR_RED}Detected incomplete or broken virtual environment. Recreating...${COLOR_RESET}"
    rm -rf "$VENV_DIR"
fi

if [[ ! -d "$VENV_DIR" ]]; then
    echo -e "${COLOR_CYAN}Creating virtual environment for tests...${COLOR_RESET}"
    python3 -m venv "$VENV_DIR" || {
        echo -e "${COLOR_RED}Failed to create venv. Python environment requirements are missing.${COLOR_RESET}" >&2
        echo -e "${COLOR_CYAN}Please run the dependency setup script first:${COLOR_RESET}" >&2
        echo -e "    ${COLOR_BOLD}bash unit_test/setup_dependencies.sh${COLOR_RESET}" >&2
        exit 1
    }
fi

# Install test dependencies
echo -e "${COLOR_CYAN}Installing test dependencies...${COLOR_RESET}"
"${VENV_DIR}/bin/pip" install flask flask-limiter -q 2>/dev/null

echo ""
echo -e "${COLOR_CYAN}Running unit tests...${COLOR_RESET}"
echo ""

# Count test files
TEST_COUNT=0
PASSED=0
FAILED=0

# Run each test file individually for better reporting
for test_file in "$TEST_DIR"/test_*.py; do
    if [[ ! -f "$test_file" ]]; then
        continue
    fi
    
    test_name=$(basename "$test_file" .py)
    TEST_COUNT=$((TEST_COUNT + 1))
    
    echo -e "${COLOR_CYAN}  Running: ${test_name}...${COLOR_RESET}"
    
    if "${VENV_DIR}/bin/python3" "$test_file" 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ ${test_name} PASSED${COLOR_RESET}"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${COLOR_RED}✗ ${test_name} FAILED${COLOR_RESET}"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

# Summary
echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
echo -e "  ${COLOR_CYAN}Test Suites: ${TEST_COUNT}${COLOR_RESET}"
echo -e "  ${COLOR_GREEN}Passed: ${PASSED}${COLOR_RESET}"
echo -e "  ${COLOR_RED}Failed: ${FAILED}${COLOR_RESET}"
echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"

if [[ $FAILED -eq 0 ]]; then
    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}✅ ALL TESTS PASSED SUCCESSFULLY!${COLOR_RESET}"
    exit 0
else
    echo ""
    echo -e "${COLOR_RED}${COLOR_BOLD}❌ ${FAILED} TEST SUITE(S) FAILED!${COLOR_RESET}" >&2
    exit 1
fi