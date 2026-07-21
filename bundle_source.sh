#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# bundle_source.sh - יוצר קובץ טקסט אחד עם כל קוד המקור של הפרויקט
# ═══════════════════════════════════════════════════════════════════════════════
# מטרה: ליצור קובץ אחד (CODE_BUNDLE.txt) שמכיל את כל קבצי הקוד, כדי לשלוח
#       לעוזר AI אחר לעבודה על הקוד. הקובץ מסנן רעש: .git, .kilo, venv,
#       node_modules, __pycache__, .pytest_cache, קבצי .pyc ותוצאות build.
#
# שימוש:
#   bash bundle_source.sh              # יוצר CODE_BUNDLE.txt בתיקיית הפרויקט
#   bash bundle_source.sh my_bundle.txt # שם קובץ מותאם
#
# הערה: להריץ על לינוקס / WSL (דורש bash + find + file).
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# תיקיית הפרויקט = המיקום של הסקריפט הזה
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

OUTPUT="${1:-CODE_BUNDLE.txt}"

# תיקיות/קבצים שיש להחריג לחלוטין (רעש, לא קוד מקור)
EXCLUDE_DIRS=(
    ".git"
    ".kilo"
    ".pytest_cache"
    "__pycache__"
    "node_modules"
    ".venv"
    "venv"
    "web/venv"
)

# תיקיות שמכילות venv במפורש (בדיקה רקורסיבית - כל נתיב שמכיל /venv/ או /site-packages/)
EXCLUDE_PATH_CONTAINS=(
    "/venv/"
    "/.venv/"
    "/site-packages/"
    "/__pycache__/"
    "/.git/"
    "/.kilo/"
    "/node_modules/"
    "/.pytest_cache/"
)
# דפוסי קבצים להחרגה
EXCLUDE_FILE_PATTERNS=(
    "*.pyc"
    "*.pyo"
    "*.so"
    "*.o"
    "*.class"
    "*.exe"
    "*.dll"
    "*.a"
    "*.lib"
    "*.zip"
    "*.tar.gz"
    "*.tgz"
    "*.png"
    "*.jpg"
    "*.jpeg"
    "*.gif"
    "*.ico"
    "*.woff"
    "*.woff2"
    "*.ttf"
    "*.eot"
    "*.pdf"
    "*.log"
    "*.lock"
    ".DS_Store"
)

# בניית פקודת find עם החרגות תיקיות (-path ... -prune)
FIND_CMD=(find . -type d)
for d in "${EXCLUDE_DIRS[@]}"; do
    FIND_CMD+=(-path "./$d" -prune -o)
done
FIND_CMD+=(-type f -print)

# הרצת find וסינון לפי דפוסי קבצים אסורים + נתיבים אסורים
mapfile -t ALL_FILES < <("${FIND_CMD[@]}" | sort)

FILTERED_FILES=()
for f in "${ALL_FILES[@]}"; do
    skip=0
    # סינון לפי סיומת (basename)
    for pat in "${EXCLUDE_FILE_PATTERNS[@]}"; do
        case "${f##*/}" in
            $pat) skip=1; break ;;
        esac
    done
    # סינון לפי נתיבים אסורים (venv, site-packages, .git וכו')
    if [[ $skip -eq 0 ]]; then
        norm_f="${f//\\//}"
        for bad in "${EXCLUDE_PATH_CONTAINS[@]}"; do
            case "$norm_f" in
                *"$bad"*) skip=1; break ;;
            esac
        done
    fi
    [[ $skip -eq 0 ]] && FILTERED_FILES+=("$f")
done

# פונקציה: האם הקובץ נראה כקובץ טקסט (ולא בינרי)
is_text() {
    local f="$1"
    if command -v file >/dev/null 2>&1; then
        local mime
        mime=$(file -b --mime-type "$f" 2>/dev/null || echo "unknown")
        case "$mime" in
            text/*|application/json|application/xml|inode/x-empty) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # fallback: בדיקת null bytes
    if grep -qI . "$f" 2>/dev/null; then return 0; else return 1; fi
}

# כתיבת ה-bundle
{
    echo "══════════════════════════════════════════════════════════════════"
    echo " USBGuard Approval Manager - Source Code Bundle"
    echo " Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " Project root: $SCRIPT_DIR"
    echo " File count: ${#FILTERED_FILES[@]}"
    echo "══════════════════════════════════════════════════════════════════"
    echo ""
} > "$OUTPUT"

count=0
for f in "${FILTERED_FILES[@]}"; do
    if [[ -f "$f" ]] && is_text "$f"; then
        {
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "FILE: $f"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            cat "$f" 2>/dev/null || echo "(unreadable)"
            echo ""
            echo ""
        } >> "$OUTPUT"
        count=$((count + 1))
    fi
done

# תיקון סופר (כמה הוחרגו כבינריים)
{
    echo "══════════════════════════════════════════════════════════════════"
    echo " Bundle complete: $count text files included."
    echo " Excluded: .git, .kilo, venv, node_modules, __pycache__, binary files."
    echo "══════════════════════════════════════════════════════════════════"
} >> "$OUTPUT"

echo "Created: $OUTPUT"
echo "Text files bundled: $count / ${#FILTERED_FILES[@]} candidates"
echo "Size: $(du -h "$OUTPUT" 2>/dev/null | cut -f1 || echo '?')"
