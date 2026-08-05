#!/bin/bash
#
# Install the SMS sync server + Cloudflare tunnel as macOS LaunchAgents so they
# start automatically on the Mac mini and restart if they crash — no Terminal
# window needed.
#
# Run this ONCE, from inside the "Server App" directory on the Mac mini:
#   cd "/path/to/tn-sms/Server App"
#   bash deploy/install-launchd.sh
#
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
TEMPLATE_DIR="$SERVER_DIR/deploy"

mkdir -p "$AGENTS" "$HOME/Library/Logs"

for name in com.tnsms.server com.tnsms.tunnel; do
    dest="$AGENTS/$name.plist"
    sed -e "s|__SERVER_DIR__|$SERVER_DIR|g" -e "s|__HOME__|$HOME|g" \
        "$TEMPLATE_DIR/$name.plist" > "$dest"
    # Reload cleanly if already installed. Enable BEFORE bootstrap: a label left
    # in launchd's disabled list makes bootstrap fail with "5: Input/output error".
    launchctl bootout "gui/$(id -u)/$name" 2>/dev/null || true
    launchctl enable "gui/$(id -u)/$name"
    launchctl bootstrap "gui/$(id -u)" "$dest"
    echo "Loaded $name"
done

echo
echo "Done. Both services are running now and will start on every login."
echo "Logs: ~/Library/Logs/tnsms-server.log  ~/Library/Logs/tnsms-tunnel.log"
echo
echo "Build the server first if you haven't: npm run build"
echo "For a headless reboot, enable auto-login:"
echo "  System Settings > Users & Groups > Automatically log in as > (this user)"
