#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Web UI Startup Script
# Version: 2.2 (Fixed)
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
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${COLOR_BOLD}║    USBGuard Web UI - Startup Assistant       ║${COLOR_RESET}"
echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
echo ""

# ── Step 1: Check Python3 ───────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo -e "${COLOR_RED}ERROR: Python3 is not installed. Please install it first.${COLOR_RESET}" >&2
    exit 1
fi
echo -e "${COLOR_GREEN}  ✓ Python3 found: $(python3 --version)${COLOR_RESET}"

# ── Step 2: Establish isolated Python Virtual Environment ───────
if [[ ! -d "$VENV_DIR" ]]; then
    echo -e "${COLOR_CYAN}[1/3] Creating secure isolated Virtual Environment (venv)...${COLOR_RESET}"
    
    # Try to create virtualenv, install python3-venv if missing
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        echo -e "${COLOR_YELLOW}  ⚠️ python3-venv is missing! Installing automatically...${COLOR_RESET}"
        
        # Detect package manager
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq || true
            sudo apt-get install -y python3-venv python3-pip -qq || {
                echo -e "${COLOR_RED}ERROR: Failed to install python3-venv. Please run: sudo apt install python3-venv python3-pip${COLOR_RESET}" >&2
                exit 1
            }
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3-virtualenv python3-pip -q || {
                echo -e "${COLOR_RED}ERROR: Failed to install python3-virtualenv${COLOR_RESET}" >&2
                exit 1
            }
        elif command -v yum &>/dev/null; then
            sudo yum install -y python3-virtualenv python3-pip -q || {
                echo -e "${COLOR_RED}ERROR: Failed to install python3-virtualenv${COLOR_RESET}" >&2
                exit 1
            }
        else
            echo -e "${COLOR_RED}ERROR: Cannot install python3-venv automatically. Please install manually.${COLOR_RESET}" >&2
            exit 1
        fi
        python3 -m venv "$VENV_DIR"
    fi
    echo -e "${COLOR_GREEN}  ✓ Virtual Environment created successfully.${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}  ✓ Isolated Virtual Environment already exists.${COLOR_RESET}"
fi

# ── Step 3: Activate venv & Install Dependencies ─────────────────
echo -e "${COLOR_CYAN}[2/3] Activating environment and installing dependencies...${COLOR_RESET}"
source "${VENV_DIR}/bin/activate"

# Upgrade pip (silent, ignore errors)
pip install --upgrade pip -q 2>/dev/null || true

# Install required packages
echo -e "  Installing Flask and Flask-Limiter..."
pip install flask flask-limiter -q 2>/dev/null || {
    echo -e "${COLOR_RED}ERROR: Failed to install Flask packages. Check network connectivity.${COLOR_RESET}" >&2
    exit 1
}

echo -e "${COLOR_GREEN}  ✓ Dependencies installed inside Virtual Environment.${COLOR_RESET}"

# Verify installation
if ! python3 -c "import flask; import flask_limiter" 2>/dev/null; then
    echo -e "${COLOR_RED}ERROR: Flask or Flask-Limiter not properly installed.${COLOR_RESET}" >&2
    exit 1
fi
echo -e "${COLOR_GREEN}  ✓ Flask $(flask --version | head -1)${COLOR_RESET}"

# ── Step 4: Ensure log directory exists ──────────────────────────
LOG_DIR="/var/log"
if [[ ! -w "$LOG_DIR" ]] && [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_YELLOW}  ⚠️ Warning: Cannot write to $LOG_DIR. Web logs may not be saved.${COLOR_RESET}"
fi

# ── Step 5: Run the web server securely ──────────────────────────
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
exec python3 "${WEB_DIR}/app.py"