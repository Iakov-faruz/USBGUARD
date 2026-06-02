#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Safe Configuration Reader
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# Parser בטוח לקריאת approval-manager.conf
# פורמט נוקשה בלבד: KEY=VALUE (ללא רווחים מסביב ל-=)
# ללא source, ללא eval, ללא הזרקת קוד
# ═══════════════════════════════════════════════════════════════

# ─── Configuration ────────────────────────────────────────────
readonly CONFIG_READER_DEFAULT_CONF="/etc/usbguard/approval-manager.conf"

# ─── Dangerous Characters Filter ──────────────────────────────
# תווים אסורים בערכי קונפיג (shell special chars)
readonly CONFIG_READER_FORBIDDEN_CHARS='[$`\;|&<>(){}[\]!]'

# ═══════════════════════════════════════════════════════════════
# פונקציה: get_conf
# תפקיד: קריאת ערך בודד מקובץ קונפיג
# שימוש: value=$(get_conf "KEY_NAME" ["/path/to/config"])
# ═══════════════════════════════════════════════════════════════
get_conf() {
    local key="$1"
    local config_file="${2:-$CONFIG_READER_DEFAULT_CONF}"
    local line value sanitized

    # ── Validation ──────────────────────────────────────────────
    if [[ -z "$key" ]]; then
        log_error "config-reader: KEY parameter is empty" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        log_error "config-reader: Config file not found: $config_file" >&2
        return 1
    fi

    if [[ ! -r "$config_file" ]]; then
        log_error "config-reader: Config file not readable: $config_file" >&2
        return 1
    fi

    # ── Validate KEY format (alphanumeric + underscores only) ───
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_error "config-reader: Invalid KEY format: '$key'" >&2
        return 1
    fi

    # ── Search for KEY=VALUE ────────────────────────────────────
    # פורמט נוקשה: KEY=VALUE (ללא רווחים מסביב ל-=)
    # מתעלם מהערות (שורות שמתחילות ב-#, גם עם רווחים לפני)
    # הערות באמצע השורה אינן נתמכות (הערך יכיל את הסולמית)
    while IFS= read -r line || [[ -n "$line" ]]; do
        # הסר רווחים מובילים
        line="${line#"${line%%[![:space:]]*}"}"

        # דלג על שורות ריקות
        [[ -z "$line" ]] && continue

        # דלג על הערות
        [[ "$line" == '#'* ]] && continue

        # הסר רווחים מובילים/מסתיימים מהשורה כולה
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # בדוק פורמט: חייב להכיל = (ולא בתור תו ראשון)
        if [[ "$line" != *'='* ]] || [[ "$line" == '='* ]]; then
            continue
        fi

        # חלץ KEY (עד התו = הראשון)
        local line_key="${line%%=*}"
        # חלץ VALUE (מהתו = הראשון עד הסוף)
        local line_value="${line#*=}"

        # הסר רווחים מסביב ל-KEY (גם whitespace מסביב ל-=)
        line_key="${line_key#"${line_key%%[![:space:]]*}"}"
        line_key="${line_key%"${line_key##*[![:space:]]}"}"

        # הסר רווחים מסביב ל-VALUE (תומך ב-"KEY = VALUE" הודות לניקוי מוקדם)
        line_value="${line_value#"${line_value%%[![:space:]]*}"}"
        line_value="${line_value%"${line_value##*[![:space:]]}"}"

        # וידוא: KEY לא מכיל תווים מיוחדים
        if [[ ! "$line_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            continue
        fi

        # השוואת KEY
        if [[ "$line_key" != "$key" ]]; then
            continue
        fi

        # ── Sanitize VALUE ──────────────────────────────────────
        value="$line_value"

        # הסר מרכאות (אם קיימות)
        if [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi

        # הסר רווחים מסביב לערך (אחרי הסרת מרכאות)
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # ── בדיקת תווים מסוכנים ─────────────────────────────────
        if echo "$value" | grep -qE "$CONFIG_READER_FORBIDDEN_CHARS" 2>/dev/null; then
            log_error "config-reader: Dangerous characters detected in value for '$key'" >&2
            return 1
        fi

        # ── Sanitization נוסף: הסר תווי control ─────────────────
        sanitized=$(echo "$value" | tr -d '[:cntrl:]' 2>/dev/null)
        if [[ "$?" -ne 0 ]]; then
            log_error "config-reader: Sanitization failed for '$key'" >&2
            return 1
        fi

        echo "$sanitized"
        return 0
    done < "$config_file"

    # KEY לא נמצא
    return 1
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: get_conf_list
# תפקיד: קריאת ערך רשימה (מופרד בפסיקים)  
# שימוש: arr=( $(get_conf_list "KEY_NAME") )
# ═══════════════════════════════════════════════════════════════
get_conf_list() {
    local key="$1"
    local config_file="${2:-$CONFIG_READER_DEFAULT_CONF}"
    local raw_value

    raw_value=$(get_conf "$key" "$config_file") || return 1

    # פיצול לפי פסיקים, הסרת רווחים סביב כל פריט
    local IFS=','
    local item
    for item in $raw_value; do
        # trim whitespace
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ -n "$item" ]]; then
            echo "$item"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: get_conf_int
# תפקיד: קריאת ערך מספרי שלם עם ברירת מחדל
# שימוש: value=$(get_conf_int "KEY_NAME" 3600)
# ═══════════════════════════════════════════════════════════════
get_conf_int() {
    local key="$1"
    local default="$2"
    local config_file="${3:-$CONFIG_READER_DEFAULT_CONF}"
    local raw_value

    raw_value=$(get_conf "$key" "$config_file") || {
        echo "$default"
        return 0
    }

    # וידוא: ערך מספרי בלבד
    if [[ "$raw_value" =~ ^[0-9]+$ ]]; then
        echo "$raw_value"
    else
        log_warn "config-reader: Expected integer for '$key', got '$raw_value'. Using default: $default" >&2
        echo "$default"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: get_conf_bool
# תפקיד: קריאת ערך בוליאני (true/false) עם ברירת מחדל
# שימוש: value=$(get_conf_bool "KEY_NAME" true)
# ═══════════════════════════════════════════════════════════════
get_conf_bool() {
    local key="$1"
    local default="$2"
    local config_file="${3:-$CONFIG_READER_DEFAULT_CONF}"
    local raw_value

    raw_value=$(get_conf "$key" "$config_file") || {
        echo "$default"
        return 0
    }

    # המרה לאותיות קטנות
    # raw_value=$(echo "$raw_value" | tr '[:upper:]' '[:lower:]')
    raw_value=$(echo "$raw_value" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    case "$raw_value" in
        true|yes|1|on)
            echo "true"
            ;;
        false|no|0|off)
            echo "false"
            ;;
        *)
            log_warn "config-reader: Expected boolean for '$key', got '$raw_value'. Using default: $default" >&2
            
            echo "$default"
            ;;
    esac

    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: validate_config_file
# תפקיד: בדיקת תקינות מלאה של קובץ קונפיג
# שימוש: validate_config_file ["/path/to/config"]
# ═══════════════════════════════════════════════════════════════
validate_config_file() {
    local config_file="${1:-$CONFIG_READER_DEFAULT_CONF}"
    local line_num=0
    local line
    local errors=0

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))

        # הסר רווחים מובילים
        line="${line#"${line%%[![:space:]]*}"}"

        # דלג על שורות ריקות והערות
        [[ -z "$line" ]] && continue
        [[ "$line" == '#'* ]] && continue

        # בדיקה: חייב להכיל =
        if [[ "$line" != *'='* ]]; then
            echo "ERROR:${config_file}:${line_num}: Missing '=' delimiter"
            ((errors++))
            continue
        fi

        # בדיקה: KEY לא יכול להתחיל ב-=
        if [[ "$line" == '='* ]]; then
            echo "ERROR:${config_file}:${line_num}: KEY is empty (line starts with '=')"
            ((errors++))
            continue
        fi

        # חלץ KEY
        local k="${line%%=*}"
        # הסר רווחים
        k="${k#"${k%%[![:space:]]*}"}"
        k="${k%"${k##*[![:space:]]}"}"

        # בדיקת KEY format
        if [[ ! "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR:${config_file}:${line_num}: Invalid KEY format: '$k'"
            ((errors++))
        fi

        # חלץ VALUE (אחרי = הראשון)
        local v="${line#*=}"
        # trim
        v="${v#"${v%%[![:space:]]*}"}"

        # בדיקת תווים מסוכנים ב-VALUE
        if echo "$v" | grep -qE "$CONFIG_READER_FORBIDDEN_CHARS" 2>/dev/null; then
            echo "ERROR:${config_file}:${line_num}: Dangerous characters in VALUE"
            ((errors++))
        fi

    done < "$config_file"

    if [[ $errors -gt 0 ]]; then
        echo "VALIDATION_FAILED: $errors error(s) found"
        return 1
    fi

    echo "VALIDATION_OK"
    return 0
}