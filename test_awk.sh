#!/bin/bash
cat << 'EOF' > /tmp/test_rules.txt
allow id 1111:2222
# ttl_epoch: 1000
EOF

now=3000
awk -v now="$now" '
BEGIN { state = 0; buffer = ""; expired_count = 0; }
{
    if (state == 0) {
        if ($0 ~ /^[[:space:]]*allow/) {
            buffer = $0
            state = 1
        } else {
            print $0
        }
    } else if (state == 1) {
        if ($0 ~ /^[[:space:]]*# ttl_epoch:[[:space:]]*[0-9]+/) {
            buffer = buffer ORS $0
            state = 2
        } else if ($0 ~ /^[[:space:]]*allow/) {
            expired_count++
            print "WARN: Discarded orphaned allow rule: " buffer > "/dev/stderr"
            buffer = $0
            state = 1
        } else if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
            buffer = buffer ORS $0
        } else {
            expired_count++
            print "WARN: Discarded orphaned allow rule (unexpected): " buffer > "/dev/stderr"
            buffer = ""
            print $0
            state = 0
        }
    } else if (state == 2) {
        split(buffer, lines, ORS)
        comment_line = lines[2]
        gsub(/^[[:space:]]*# ttl_epoch:[[:space:]]*/, "", comment_line)
        gsub(/[[:space:]]*$/, "", comment_line)
        epoch = int(comment_line)

        if (epoch <= now) {
            expired_count++
            state = 0
            buffer = ""
        } else {
            print buffer
            state = 3
            buffer = ""
        }
    } else if (state == 3) {
        print $0
        state = 0
    }
}
END {
    if (state == 1 && length(buffer) > 0) {
        expired_count++
        print "WARN: Discarded trailing orphaned allow rule: " buffer > "/dev/stderr"
    }
    # ADDED LOGIC HERE for state == 2 trailing
    if (state == 2 && length(buffer) > 0) {
        split(buffer, lines, ORS)
        comment_line = lines[2]
        gsub(/^[[:space:]]*# ttl_epoch:[[:space:]]*/, "", comment_line)
        gsub(/[[:space:]]*$/, "", comment_line)
        epoch = int(comment_line)
        if (epoch <= now) {
            expired_count++
        } else {
            print buffer
        }
    }
    print "EXPIRED_COUNT=" expired_count > "/dev/stderr"
}
' /tmp/test_rules.txt
