#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager – Safe Configuration Reader
# Version: 3.2 (Hardened, Zero‑Subprocess, Production‑Grade)
# ════════════════════════════════════════════════════════════════════════
#
# מטרה:
#   קריאה בטוחה, מהירה ומוקשחת של פרמטרים מקובץ קונפיגורציה.
#
# עקרונות:
#   • ללא eval / source של קובץ קונפיגורציה.
#   • ללא grep / sed / awk / tr חיצוניים (Zero‑Subprocess).
#   • כל ערך עובר סניטיזציה + בדיקת תווים מסוכנים.
#   • תמיכה בערכים: טקסט, מספרים, בוליאנים, רשימות (CSV).
#   • כולל validate_config_file לוולידציה מלאה של הקובץ.
#
# פורמט קובץ נתמך:
#   KEY=value
#   KEY = value
#   KEY="value with spaces"
#   # הערות מתחילות בסולמית
#
# ════════════════════════════════════════════════════════════════════════

readonly CONFIG_READER_DEFAULT_CONF="/etc/usbguard/approval-manager.conf"

# רשימת תווים אסורים בהחלט בערכי קונפיגורציה (מניעת Shell Injection)
# כולל: $, `, |, &, <, >, (, ), {, }, [, ], !, ;
readonly _CONF_FORBIDDEN_CHARS='$`|&<>(){}[]!;'

# ───────────────────────────────────────────────────────────────────────
# פונקציית עזר: _trim
# מסירה רווחים/טאבים מתחילת וסוף מחרוזת (ללא subprocess).
# ───────────────────────────────────────────────────────────────────────
_trim() {
    local s="$1"
    # הסרת רווחים בתחילת המחרוזת
    s="${s#"${s%%[![:space:]]*}"}"
    # הסרת רווחים בסוף המחרוזת
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_conf_contains_forbidden_char() {
    local value="$1"
    local i ch
    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:i:1}"
        case "$ch" in
            '$'|'`'|'|'|'&'|'<'|'>'|'('|')'|'{'|'}'|'['|']'|'!'|';')
                return 0
                ;;
        esac
    done
    return 1
}

# ───────────────────────────────────────────────────────────────────────
# get_conf — קריאת ערך טקסטואלי
# Args:
#   $1: KEY
#   $2: קובץ קונפיגורציה (אופציונלי)
# Return:
#   stdout: הערך הנקי
#   exit 0: הצלחה
#   exit 1: שגיאה / לא נמצא
# ───────────────────────────────────────────────────────────────────────
get_conf() {
    local key="$1"
    local config_file="${2:-$CONFIG_READER_DEFAULT_CONF}"
    local line line_key line_value

    # וידוא מפתח
    if [[ -z "$key" ]]; then
        echo "ERROR: [config-reader] Key is empty" >&2
        return 1
    fi
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: [config-reader] Invalid KEY format: '$key'" >&2
        return 1
    fi

    # וידוא קובץ
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: [config-reader] Config file not found: $config_file" >&2
        return 1
    fi
    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: [config-reader] Config file not readable: $config_file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # ניקוי רווחים בתחילת השורה
        line="$(_trim "$line")"

        # דילוג על ריק / הערות
        [[ -z "$line" || "$line" == '#'* ]] && continue

        # חייב להכיל '=' ולא להתחיל ב'='
        [[ "$line" == *=* && "$line" != '='* ]] || continue

        line_key="${line%%=*}"
        line_value="${line#*=}"

        line_key="$(_trim "$line_key")"
        line_value="$(_trim "$line_value")"

        # מפתח לא חוקי → דילוג
        [[ "$line_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        # מצאנו את המפתח
        if [[ "$line_key" == "$key" ]]; then
            # אם הערך מוקף בגרשיים כפולים — הסרה
            if [[ "$line_value" == \"*\" && "${#line_value}" -ge 2 ]]; then
                line_value="${line_value:1:${#line_value}-2}"
            fi

            # ניקוי נוסף אחרי הסרת גרשיים
            line_value="$(_trim "$line_value")"

            # בדיקת תווים מסוכנים
            if _conf_contains_forbidden_char "$line_value"; then
                echo "ERROR: [config-reader] Dangerous characters detected in value for '$key'" >&2
                return 1
            fi

            printf '%s\n' "$line_value"
            return 0
        fi
    done < "$config_file"

    return 1
}

# ───────────────────────────────────────────────────────────────────────
# get_conf_list — ערכים מופרדים בפסיקים (CSV)
# Args:
#   $1: KEY
#   $2: קובץ (אופציונלי)
# Return:
#   כל ערך בשורה נפרדת
# ───────────────────────────────────────────────────────────────────────
get_conf_list() {
    local key="$1"
    local config_file="${2:-$CONFIG_READER_DEFAULT_CONF}"
    local raw_value

    raw_value=$(get_conf "$key" "$config_file") || return 1

    local IFS=','
    local item
    for item in $raw_value; do
        item="$(_trim "$item")"
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

# ───────────────────────────────────────────────────────────────────────
# get_conf_int — ערך מספרי
# Args:
#   $1: KEY
#   $2: DEFAULT
#   $3: קובץ (אופציונלי)
# ───────────────────────────────────────────────────────────────────────
get_conf_int() {
    local key="$1"
    local default="$2"
    local config_file="${3:-$CONFIG_READER_DEFAULT_CONF}"
    local val

    val=$(get_conf "$key" "$config_file") || { printf '%s\n' "$default"; return 0; }

    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$val"
    else
        echo "WARN: [config-reader] Expected integer for '$key', got '$val'. Using default: $default" >&2
        printf '%s\n' "$default"
    fi
}

# ───────────────────────────────────────────────────────────────────────
# get_conf_bool — ערך בוליאני
# Args:
#   $1: KEY
#   $2: DEFAULT (true/false)
#   $3: קובץ (אופציונלי)
# ───────────────────────────────────────────────────────────────────────
get_conf_bool() {
    local key="$1"
    local default="$2"
    local config_file="${3:-$CONFIG_READER_DEFAULT_CONF}"
    local raw_value

    # קריאה בטוחה, אם נכשל מחזירים דיפולט
    raw_value=$(get_conf "$key" "$config_file") || { printf '%s\n' "$default"; return 0; }

    # המרה ל-lowercase ללא subprocess
    raw_value="${raw_value,,}"
    # הסרת רווחים מהקצוות בלבד בעזרת פונקציית ה-trim הקיימת שלך
    raw_value="$(_trim "$raw_value")"

    case "$raw_value" in
        true|yes|1|on)  printf 'true\n' ;;
        false|no|0|off) printf 'false\n' ;;
        *)
            echo "WARN: [config-reader] Expected boolean for '$key', got '$raw_value'. Using default: $default" >&2
            printf '%s\n' "$default"
            ;;
    esac
    return 0
}

# ───────────────────────────────────────────────────────────────────────
# validate_config_file — ולידציה מלאה של קובץ קונפיגורציה
# Args:
#   $1: קובץ קונפיגורציה (אופציונלי, ברירת מחדל: $CONFIG_READER_DEFAULT_CONF)
# Return:
#   VALIDATION_OK  – אם הקובץ תקין לחלוטין
#   VALIDATION_FAILED – אם נמצאו שגיאות (קוד יציאה 1)
# תפקיד:
#   • בדיקת תקינות תחבירית של KEY=VALUE
#   • מניעת Shell Injection באמצעות Regex קשיח
#   • תמיכה בערכים עם גרשיים כפולים
#   • Zero‑Subprocess (ללא grep/sed/awk)
#   • בטוח לחלוטין תחת set -euo pipefail
# ───────────────────────────────────────────────────────────────────────
validate_config_file() {
    local config_file="${1:-$CONFIG_READER_DEFAULT_CONF}"
    local line_num=0
    local line
    local errors=0

    # בדיקה ראשונית: האם הקובץ קיים?
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file"
        return 1
    fi

    # קריאה שורה-שורה, כולל שורה אחרונה ללא \n
    while IFS= read -r line || [[ -n "$line" ]]; do
        
        # השמה אריתמטית בטוחה לחלוטין תחת set -e
        line_num=$((line_num + 1))

        # ניקוי רווחים
        line="$(_trim "$line")"

        # דילוג על שורות ריקות או הערות
        [[ -z "$line" || "$line" == '#'* ]] && continue

        # חייב להכיל '='
        if [[ "$line" != *'='* ]]; then
            echo "ERROR:${config_file}:${line_num}: Missing '=' delimiter"
            errors=$((errors + 1))
            continue
        fi

        # לא יכול להתחיל ב'=' → KEY ריק
        if [[ "$line" == '='* ]]; then
            echo "ERROR:${config_file}:${line_num}: KEY is empty (line starts with '=')"
            errors=$((errors + 1))
            continue
        fi

        # פיצול KEY=VALUE
        local k="${line%%=*}"
        local v="${line#*=}"

        k="$(_trim "$k")"
        v="$(_trim "$v")"

        # בדיקת תקינות KEY (אות/קו תחתון בתחילת מחרוזת)
        if [[ ! "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR:${config_file}:${line_num}: Invalid KEY format: '$k'"
            errors=$((errors + 1))
        fi

        # אם הערך מוקף בגרשיים כפולים — קילוף
        # "DEBUG" → DEBUG
        if [[ "$v" == \"*\" && "${#v}" -ge 2 ]]; then
            v="${v:1:${#v}-2}"
            v="$(_trim "$v")"
        fi

        # בדיקת תווים מסוכנים
        if _conf_contains_forbidden_char "$v"; then
            echo "ERROR:${config_file}:${line_num}: Dangerous characters in VALUE"
            errors=$((errors + 1))
        fi

    done < "$config_file"

    # סיכום
    if [[ $errors -gt 0 ]]; then
        echo "VALIDATION_FAILED: $errors error(s) found"
        return 1
    fi

    echo "VALIDATION_OK"
    return 0
}
