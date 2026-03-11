#!/bin/bash
# ----------------------------------------------------------------
# Script: deploy_checkmk_plugins.sh
# Purpose: Deploy Checkmk plugins for user password expiration and logins
# Compatible with Ubuntu / RHEL
# Run as root
# ----------------------------------------------------------------

PLUGIN_DIR="/usr/lib/check_mk_agent/plugins"

echo "Deploying Checkmk plugins to $PLUGIN_DIR..."

# Create plugin directory if it doesn't exist
mkdir -p "$PLUGIN_DIR"

# -------------------------------
# mk-logins plugin
# -------------------------------
cat > "$PLUGIN_DIR/mk-logins" <<'EOF'
#!/bin/bash
# Checkmk plugin to count logged-in users

# Disable unused variable error
CMK_VERSION="2.4.0p20"

if type who >/dev/null; then
    echo "<<<logins>>>"
    who | wc -l
fi
EOF

# -------------------------------
# mk-passwd plugin
# -------------------------------
cat > "$PLUGIN_DIR/mk-passwd" <<'EOF'
#!/bin/bash
# Checkmk plugin to monitor password expiration

echo "<<<local:sep(0)>>>"

# Thresholds
WARN=3
CRIT=1

# Loop over users in /etc/passwd
while IFS=: read -r user _ uid _ _ _ _; do
    [[ "$uid" -lt 1000 ]] && continue  # skip system users

    # Get password expiry date
    expire=$(chage -l "$user" 2>/dev/null | awk -F": " '/Password expires/ {print $2}')
    [[ -z "$expire" || "$expire" == "never" ]] && continue

    # Calculate days left
    days_left=$(( ( $(date -d "$expire" +%s) - $(date +%s) ) / 86400 ))

    # Determine state
    if [ "$days_left" -le $CRIT ]; then
        state=2
    elif [ "$days_left" -le $WARN ]; then
        state=1
    else
        state=0
    fi

    # Output local check line
    echo "$state passwd_$user days_left=$days_left Password for user $user expires in $days_left day(s)"
done < /etc/passwd
EOF

# Make plugins executable
chmod +x "$PLUGIN_DIR/mk-logins" "$PLUGIN_DIR/mk-passwd"

echo "Plugins deployed successfully!"
echo "-----------------------------------"
echo "Test mk-logins:"
"$PLUGIN_DIR/mk-logins"
echo "-----------------------------------"
echo "Test mk-passwd:"
"$PLUGIN_DIR/mk-passwd"
echo "-----------------------------------"

echo "Done. You can now run service discovery on Checkmk Web UI."
