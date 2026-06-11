#!/usr/bin/env python3
"""Fix config-reader.sh forbidden chars regex"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "scripts/lib/config-reader.sh"

with open(path, 'r') as f:
    content = f.read()

# The bug: '[$`\;|&<>(){}[\]!]' - backslash before ; makes it match literal \ not ;
# Fixed: '[$`;|&<>(){}[\]!]' - remove the backslash before ;
old = "[$`\\;|&<>(){}[\\]!]"
new = "[$`;|&<>(){}[\\]!]"

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print(f"FIXED: {path}")
    print(f"  Was: ...{old}...")
    print(f"  Now: ...{new}...")
elif new in content:
    print(f"ALREADY FIXED: {path}")
else:
    print(f"PATTERN NOT FOUND in {path}")
    # Find what's actually there
    import re
    match = re.search(r"CONFIG_READER_FORBIDDEN_CHARS='([^']+)'", content)
    if match:
        print(f"  Current value: {match.group(1)}")
    sys.exit(1)