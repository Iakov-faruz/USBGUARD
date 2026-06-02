#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Web UI Startup Script
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# סקריפט להרצה מבודדת ובטוחה של ממשק ה-Web במחשב שלך
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${WEB_DIR}/venv"

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${COLOR_BOLD}║    USBGuard Web UI - Startup Assistant       ║${COLOR_RESET}"
echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
echo ""

# ── Step 1: Check Python3 & virtual environment packages ───────
if ! command -v python3 &>/dev/null; then
    echo "ERROR: Python3 is not installed on your system. Please install it first." >&2
    exit 1
fi

# ── Step 2: Establish isolated Python Virtual Environment ───────
if [[ ! -d "$VENV_DIR" ]]; then
    echo -e "${COLOR_CYAN}[1/3] Creating secure isolated Virtual Environment (venv)...${COLOR_RESET}"
    
    # Try to create virtualenv, install python3-venv if missing
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        echo -e "${COLOR_YELLOW}  ⚠️ python3-venv is missing! Installing automatically...${COLOR_RESET}"
        sudo apt-get update -qq || true
        sudo apt-get install -y python3-venv python3-pip -qq || {
            echo "ERROR: Failed to install python3-venv. Please run: sudo apt install python3-venv" >&2
            exit 1
        }
        python3 -m venv "$VENV_DIR"
    fi
    echo -e "${COLOR_GREEN}  ✓ Virtual Environment created successfully.${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}  ✓ Isolated Virtual Environment already exists.${COLOR_RESET}"
fi

# ── Step 3: Activate venv & Install Flask ───────────────────────
echo -e "${COLOR_CYAN}[2/3] Activating environment and installing Flask...${COLOR_RESET}"
source "${VENV_DIR}/bin/activate"

# Upgrade pip and install flask inside the isolated sandbox
pip install --upgrade pip -q 2>/dev/null || true
pip install flask -q

echo -e "${COLOR_GREEN}  ✓ Dependencies installed inside Virtual Environment.${COLOR_RESET}"

# ── Step 4: Run the web server securely ──────────────────────────
echo -e "${COLOR_CYAN}[3/3] Starting secure local Web UI server...${COLOR_RESET}"
echo ""
echo -e "  ${COLOR_BOLD}════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "  ${COLOR_GREEN}${COLOR_BOLD}  🚀 USBGUARD WEB UI IS NOW ONLINE!${COLOR_RESET}"
echo -e "  ${COLOR_BOLD}════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "  • Local Address:   ${COLOR_CYAN}${COLOR_BOLD}http://127.0.0.1:5000${COLOR_RESET}"
echo -e "  • Access Security: Isolated local loopback only (127.0.0.1)"
echo -e "  • User Context:    Running securely as user: ${COLOR_BOLD}$(whoami)${COLOR_RESET}"
echo -e "  • Control Key:     Press ${COLOR_BOLD}Ctrl + C${COLOR_RESET} to shutdown the web server."
echo -e "  ${COLOR_BOLD}════════════════════════════════════════════════════════${COLOR_RESET}"
echo ""

# Run Flask app
python3 "${WEB_DIR}/app.py"
