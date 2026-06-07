#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
echo "=== Validating all scripts in USBGUARD1 ==="
errors=0
for f in deploy.sh scripts/*.sh; do
    if [ -f "$f" ]; then
        echo -n "$f: "
        if bash -n "$f" 2>/dev/null; then
            echo "OK"
        else
            echo "FAIL"
            ((errors++))
        fi
    fi
done
echo ""
if [ $errors -eq 0 ]; then
    echo "All scripts passed syntax validation"
else
    echo "$errors script(s) failed"
fi
exit $errors