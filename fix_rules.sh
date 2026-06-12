#!/bin/bash
cat << 'EOF' > /etc/usbguard/rules.d/00-system.rules
allow id 1d6b:0001 with-interface 09:00:00
allow id 1d6b:0002 with-interface 09:00:00
allow id 1d6b:0003 with-interface 09:00:00
allow id 80ee:0021
allow id *:* with-interface 03:00:00
allow id *:* with-interface 03:01:00
allow id *:* with-interface 03:01:01
allow id *:* with-interface 03:01:02
EOF

echo "" > /etc/usbguard/rules.d/50-permanent.rules
echo "" > /etc/usbguard/rules.d/90-temporary.rules
systemctl restart usbguard
systemctl status usbguard
