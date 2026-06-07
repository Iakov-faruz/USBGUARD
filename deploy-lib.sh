#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Deployment Library
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# פונקציות עזר משותפות לסקריפטי deployment
# נטען ע"י: source deploy-lib.sh
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# Utility Functions
# ═══════════════════════════════════════════════════════════════

log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"
}

log_ok() {
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"
    ((WARNINGS++))
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"
    ((ERRORS++))
}

log_header() {
    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║  $*${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
}

run_cmd() {
    local desc="$1"
    shift
    echo -e "  → ${desc}..." | tee -a "$DEPLOY_LOG"
    if "$@" 2>&1 | tee -a "$DEPLOY_LOG"; then
        log_ok "${desc}"
        return 0
    else
        log_error "${desc}"
        return 1
    fi
}