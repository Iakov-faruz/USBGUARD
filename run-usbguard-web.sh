#!/bin/bash
# ==============================================================================
# USBGuard Web Interface - Launch Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_FILE="${SCRIPT_DIR}/app.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  dev, debug     Run in DEBUG mode (full error details)"
    echo "  prod, production Run in PRODUCTION mode (sanitized errors)"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dev         # Run with debugging enabled"
    echo "  $0 prod        # Run in production mode"
    echo ""
}

case "$1" in
    dev|debug)
        echo -e "${YELLOW}🔧 Starting USBGuard Web Interface in DEBUG mode...${NC}"
        export FLASK_DEBUG=true
        sudo -E python3 "$APP_FILE"
        ;;
    prod|production)
        echo -e "${GREEN}🔒 Starting USBGuard Web Interface in PRODUCTION mode...${NC}"
        export FLASK_DEBUG=false
        sudo -E python3 "$APP_FILE"
        ;;
    -h|--help|help)
        show_help
        exit 0
        ;;
    *)
        echo -e "${RED}❌ Invalid option: $1${NC}"
        show_help
        exit 1
        ;;
esac

# # 3. הרץ במצב דיבוג (לפיתוח):
# ./run.sh dev

# # 4. הרץ במצב ייצור (לסביבת עבודה):
# ./run.sh prod

# # 5. או ישירות עם משתנה סביבה:
# sudo FLASK_DEBUG=true python3 app.py     # מצב דיבוג
# sudo FLASK_DEBUG=false python3 app.py    # מצב ייצור