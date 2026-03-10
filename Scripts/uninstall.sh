#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/Applications"
BINARY_NAME="CCBar"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== CCBar Uninstaller ==="

# Step 1: Kill running process
echo "Stopping CCBar..."
pkill -f "$BINARY_NAME" 2>/dev/null || true

# Step 2: Remove binary
if [ -f "$INSTALL_DIR/$BINARY_NAME" ]; then
    rm "$INSTALL_DIR/$BINARY_NAME"
    echo "Removed $INSTALL_DIR/$BINARY_NAME"
else
    echo "Binary not found at $INSTALL_DIR/$BINARY_NAME"
fi

# Step 3: Remove hooks from settings.json
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q "localhost:27182" "$SETTINGS_FILE" 2>/dev/null; then
        echo "Removing hooks from $SETTINGS_FILE..."
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup"

        python3 -c "
import json, os

settings_file = os.path.expanduser('~/.claude/settings.json')

with open(settings_file, 'r') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
cleaned_hooks = {}

for event_name, matchers in hooks.items():
    cleaned_matchers = []
    for matcher in matchers:
        hook_list = matcher.get('hooks', [])
        filtered = [h for h in hook_list if 'localhost:27182' not in h.get('command', '')]
        if filtered:
            matcher['hooks'] = filtered
            cleaned_matchers.append(matcher)
    if cleaned_matchers:
        cleaned_hooks[event_name] = cleaned_matchers

settings['hooks'] = cleaned_hooks

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
"
        echo "Hooks removed. Backup at $SETTINGS_FILE.backup"
    else
        echo "No CCBar hooks found in $SETTINGS_FILE"
    fi
fi

echo ""
echo "=== Uninstallation Complete ==="
