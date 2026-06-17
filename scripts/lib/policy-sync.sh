#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Policy Sync Module
# Version: 3.6 (Bug-Fixed, Subshell-Optimized, Enterprise-Grade)
# ══════════════════════════════════════════════════════════════════════════════
#
# ארכיטקטורה והסבר:
#   התיעוד הרשמי של USBGuard (גרסאות 1.0 ומעלה) מגדיר עבודה מול קובץ פוליסי יחיד
#   (RuleFile) המוגדר ב-usbguard-daemon.conf (לרוב /etc/usbguard/rules.conf).
#   הוא אינו תומך טבעית בטעינת תיקיית קבצים (RuleFolder).
#
#   כדי לאפשר ניהול מודולרי, המנג'ר מחזיק קבצים נפרדים בתיקיית משנה (rules.d):
#     - 00-system.rules    (חוקי מערכת בסיסיים והתקנים מובנים)
#     - 50-permanent.rules (התקנים שאושרו לצמיתות ע"י מנהל המערכת)
#     - 90-temporary.rules (התקנים זמניים המנוהלים עם מנגנון TTL)
#
#   לפני ביצוע Reload לשירות, מודול זה מייצר אינטגרציה (לכיוד) של כל הקבצים
#   הללו, מעביר אותם סניטיזציה, מוודא וולידציית סינטקס מלאה, ומחליף את
#   הקובץ הראשי (rules.conf) בצורה אטומיקלית (Atomic MV).
#
# ══════════════════════════════════════════════════════════════════════════════

# מניעת טעינה כפולה של המודול בזיכרון אם הוא מורץ כחלק מ-source
if [[ "${USBGUARD_POLICY_SYNC_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
USBGUARD_POLICY_SYNC_LOADED=1

# וידוא קיום פונקציית הוולידציה ההכרחית מספרית ה-validator
if ! declare -F validate_usbguard_rule_file >/dev/null 2>&1; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rules-validator.sh" 2>/dev/null || {
        echo "ERROR: policy-sync requires rules-validator.sh" >&2
        return 1 2>/dev/null || exit 1
    }
fi

# ─── קבועים קשיחים (Defaults) ────────────────────────────────────────────────
readonly POLICY_SYNC_DEFAULT_RULES_DIR="/etc/usbguard/rules.d"
readonly POLICY_SYNC_DEFAULT_RULES_FILE="/etc/usbguard/rules.conf"
readonly POLICY_SYNC_REQUIRED_RULES=(00-system.rules 50-permanent.rules 90-temporary.rules)

# ─── פונקציית עזר פנימית לניהול לוגים ──────────────────────────────────────────
_sync_log_err() {
    local msg="$1"
    # כתיבה ללוג המערכת אם הפונקציה זמינה, אחרת רק ל-stderr
    if declare -F log_error >/dev/null 2>&1; then
        log_error "POLICY" "$msg" 2>/dev/null || true
    fi
    echo "ERROR: $msg" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_sanitize_rule
# מטרה: ניקוי שורת חוק בודדת מרווחים כפולים ושדות דינמיים מיותרים.
# למה? USBGuard נוטה להוסיף 'parent-hash' ו-'with-connect-type' בזמן ריצה.
#      השדות הללו משתנים דינמית ומשבשים השוואות וולידציה (כי הם לא בקבצי המקור).
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_sanitize_rule() {
    local line="$1"

    # אם השורה היא הערה או ריקה לחלוטין - החזר אותה כמו שהיא ללא שינוי
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
        printf '%s\n' "$line"
        return 0
    fi

    # ניקוי השדות באמצעות sed והסרת רווחים מיותרים בקצוות ובמרכז
    line=$(printf '%s\n' "$line" | sed -E \
        -e 's/[[:space:]]+parent-hash[[:space:]]+"[^"]*"//g' \
        -e 's/[[:space:]]+with-connect-type[[:space:]]+("[^"]*"|[^[:space:]]+)//g' \
        -e 's/[[:space:]]{2,}/ /g' \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]+$//')

    printf '%s\n' "$line"
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_device_signature
# מטרה: חילוץ מזהה החומרה הצר (id + interface) מתוך שורת חוק מלאה.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_device_signature() {
    local rule="$1"
    local id_value=""
    local interface_value=""

    # חילוץ ה-Vendor:Product ID (למשל 1d6b:0002)
    if [[ "$rule" =~ (^|[[:space:]])id[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4}) ]]; then
        id_value="${BASH_REMATCH[2]}"
    fi

    # חילוץ מחרוזת ה-interfaces במידה וקיימת
    if [[ "$rule" =~ with-interface[[:space:]]+([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}) ]]; then
        interface_value="${BASH_REMATCH[1]}"
    fi

    # בניית חתימה נקייה על בסיס השדות שחולצו
    if [[ -n "$id_value" && -n "$interface_value" ]]; then
        printf 'id %s with-interface %s\n' "$id_value" "$interface_value"
    else
        policy_sync_sanitize_rule "$rule"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_rule_signature
# מטרה: יצירת חתימת השוואה קנונית המתחילה ב-allow.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_rule_signature() {
    local rule="$1"
    local device_signature
    
    device_signature=$(policy_sync_device_signature "$rule")
    if [[ "$device_signature" == id:* || "$device_signature" == id[[:space:]]* ]]; then
        printf 'allow %s\n' "$device_signature"
    else
        policy_sync_sanitize_rule "$rule"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_normalize_active_rules
# מטרה: שליפת כל החוקים האקטיביים מתוך זכרון ה-Daemon ונרמולם.
# אופטימיזציה: שימוש ב-Process Substitution מונע יצירת תת-תהליך (Subshell)
#              ללולאת ה-while, מה שמונע אובדן משתנים ומקפיץ ביצועים.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_normalize_active_rules() {
    local rule_line

    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        policy_sync_rule_signature "$rule_line"
    # הזרמת פלט הפקודה ישירות ללולאה ללא שימוש ב-Pipe (|)
    done < <(usbguard list-rules 2>/dev/null | sed -E 's/^[[:space:]]*[0-9]+:[[:space:]]*//')
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_rules_dir
# מטרה: וידוא קיום של תיקיית החוקים וכל קבצי המקור הנדרשים.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_rules_dir() {
    local rules_dir="${1:-$POLICY_SYNC_DEFAULT_RULES_DIR}"
    
    if [[ ! -d "$rules_dir" ]]; then
        _sync_log_err "Rules directory missing: $rules_dir"
        return 1
    fi

    local missing=0
    local rule_file
    
    for rule_file in "${POLICY_SYNC_REQUIRED_RULES[@]}"; do
        if [[ ! -f "${rules_dir}/${rule_file}" ]]; then
            _sync_log_err "Required rules file missing: ${rules_dir}/${rule_file}"
            missing=$((missing + 1))
        fi
    done

    if [[ "$missing" -ne 0 ]]; then 
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_build_policy_file
# מטרה: קומפילציה אטומית ומאובטחת של קבצי ה-rules.d לקובץ rules.conf אחד.
# אבטחה: בנייה בקובץ זמני (mktemp) -> וולידציית סינטקס -> החלפה אטומית (mv).
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_build_policy_file() {
    local rules_dir="${1:-$POLICY_SYNC_DEFAULT_RULES_DIR}"
    local rules_file="${2:-$POLICY_SYNC_DEFAULT_RULES_FILE}"
    local tmp_file=""
    local rule_file
    local rule_line

    # 1. וידוא קיום קבצי המקור
    policy_sync_rules_dir "$rules_dir" || return 1

    # 2. יצירת קובץ זמני מאובטח
    tmp_file=$(mktemp -t usbguard_policy_sync_XXXXXX 2>/dev/null) || {
        _sync_log_err "Cannot create temporary policy file"
        return 1
    }

    # 3. איפוס הקובץ הזמני ווידוא הרשאות כתיבה
    : > "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null
        _sync_log_err "Cannot initialize temporary policy file"
        return 1
    }

    # 4. שרשור מנורמל של כל הקבצים לקובץ אחד, עם בלוקים ברורים של תחילת/סוף קובץ
    for rule_file in "${POLICY_SYNC_REQUIRED_RULES[@]}"; do
        if [[ -s "${rules_dir}/${rule_file}" ]]; then
            printf '\n# BEGIN %s\n' "$rule_file" >> "$tmp_file"
            
            # קריאה וניקוי של שורות ריקות מחוקי המקור באמצעות Process Substitution מובטח
            while IFS= read -r rule_line; do
                [[ -z "$rule_line" ]] && continue
                policy_sync_sanitize_rule "$rule_line" >> "$tmp_file"
            done < <(sed '/^[[:space:]]*$/d' "${rules_dir}/${rule_file}" 2>/dev/null || true)
            
            printf '# END %s\n' "$rule_file" >> "$tmp_file"
        fi
    done

    # 5. וולידציה קשיחה (בדיקה שהסינטקס המאוחד לא שבור ולא יפיל את ה-Daemon)
    if ! validate_usbguard_rule_file "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null
        return 1
    fi

    # 6. יצירת תיקיית היעד אם אינה קיימת
    mkdir -p "$(dirname "$rules_file")" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null
        return 1
    }

    # 7. החלפה אטומית (Atomic Swap) - מונע מצב של קובץ חלקי/פגום במקרה של קריסת כוח
    if ! mv "$tmp_file" "$rules_file"; then
        rm -f "$tmp_file" 2>/dev/null
        return 1
    fi

    # 8. הקשחת הרשאות חיונית לקובץ הפוליסי האקטיבי (רק ל-root יש גישה)
    chmod 600 "$rules_file" 2>/dev/null || true
    chown root:root "$rules_file" 2>/dev/null || true
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_verify_active
# מטרה: אימות בזמן אמת שהחוקים שבקובץ אכן נטענו והפכו לאקטיביים ב-Daemon.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_verify_active() {
    local expected_file="${1:-$POLICY_SYNC_DEFAULT_RULES_FILE}"
    local active_rules file_rules

    if [[ ! -f "$expected_file" ]]; then
        _sync_log_err "Policy file missing after sync: $expected_file"
        return 1
    fi

    active_rules=$(policy_sync_normalize_active_rules)
    file_rules=$(sed 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d' "$expected_file" 2>/dev/null || true)

    if [[ -z "$active_rules" ]]; then
        _sync_log_err "USBGuard active policy is empty"
        return 1
    fi

    local rule_line rule_signature
    # תיקון קריטי: החלפת ה-Here-String (<<<) ב-Process Substitution למניעת שבירת לולאה בריבוי שורות
    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        rule_signature=$(policy_sync_rule_signature "$rule_line")
        
        # וידוא שכל חוק מהקובץ מופיע במערך החוקים האקטיביים של השירות
        if [[ -z "$rule_signature" ]] || [[ "$active_rules" != *"$rule_signature"* ]]; then
            _sync_log_err "Active policy missing rule signature: $rule_signature"
            return 1
        fi
    done < <(echo "$file_rules")
    
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# policy_sync_reload_daemon
# מטרה: הפעלת מנגנון טעינה מחדש מדורג (Cascading Fallback).
# סדר פעולות: ניסיון systemctl reload -> ניסיון systemctl restart -> סיגנל SIGHUP.
# ──────────────────────────────────────────────────────────────────────────────
policy_sync_reload_daemon() {
    local rules_dir="${1:-$POLICY_SYNC_DEFAULT_RULES_DIR}"
    local rules_file="${2:-$POLICY_SYNC_DEFAULT_RULES_FILE}"
    local reload_success=false
    local attempt

    # קומפילציית הקובץ תחילה
    policy_sync_build_policy_file "$rules_dir" "$rules_file" || return 1

    # מנגנון Fallback מדורג לטעינת החוקים
    if ! timeout 60 systemctl reload usbguard 2>/dev/null; then
        # אם reload נכשל/לא נתמך, מנסים הפעלה מחדש מלאה
        if ! timeout 60 systemctl restart usbguard 2>/dev/null; then
            # קו הגנה אחרון: שליחת סיגנל HUP ישירות ל-PID של ה-Daemon (למערכות ללא systemd)
            if pgrep -x usbguard-daemon >/dev/null 2>&1; then
                pkill -HUP usbguard-daemon 2>/dev/null || true
                sleep 2
            fi
        fi
    fi

    # לולאת בדיקה (עד 30 שניות) לוודא שהשירות חזר למצב אקטיבי ויציב
    for attempt in {1..30}; do
        if systemctl is-active --quiet usbguard 2>/dev/null; then
            reload_success=true
            break
        fi
        sleep 1
    done

    if [[ "$reload_success" != "true" ]]; then
        _sync_log_err "USBGuard service is not active after reload attempt"
        return 1
    fi

    # וידוא סופי שהחוקים החדשים אכן נקלטו רשמית במנוע האכיפה
    policy_sync_verify_active "$rules_file" || return 1
    return 0
}