#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Install Test & System Dependencies
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${COLOR_BOLD}║    USBGuard Dependency Installer             ║${COLOR_RESET}"
echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
echo ""

# Packages needed
PACKAGES=(python3-pip python3-venv python3-evdev)
MISSING_PACKAGES=()

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [[ ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
    echo -e "${COLOR_GREEN}✓ All system dependencies are already installed: ${PACKAGES[*]}${COLOR_RESET}"
    exit 0
fi

echo -e "${COLOR_CYAN}The following system packages are missing and need to be installed: ${COLOR_BOLD}${MISSING_PACKAGES[*]}${COLOR_RESET}"
echo -e "${COLOR_CYAN}Requesting root privileges via sudo...${COLOR_RESET}"
echo ""

if sudo apt-get update && sudo apt-get install -y "${MISSING_PACKAGES[@]}"; then
    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}✓ Dependencies installed successfully!${COLOR_RESET}"
    exit 0
else
    echo ""
    echo -e "${COLOR_RED}${COLOR_BOLD}❌ Failed to install dependencies. Please run the command manually: ${COLOR_RESET}"
    echo "    sudo apt install -y ${MISSING_PACKAGES[*]}"
    exit 1
fi
