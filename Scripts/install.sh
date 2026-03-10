#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="$HOME/Applications"
BINARY_NAME="CCBar"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== CCBar Installer ==="

# Step 1: Build
echo "Building..."
cd "$PROJECT_DIR"
swift build -c release

# Step 2: Create .app bundle
APP_NAME="CCBar.app"
APP_DIR="$INSTALL_DIR/$APP_NAME"
MACOS_DIR="$APP_DIR/Contents/MacOS"
echo "Creating $APP_DIR..."
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

# Copy binary
cp ".build/release/$BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
chmod +x "$MACOS_DIR/$BINARY_NAME"

# Create Info.plist (LSUIElement=true hides from Dock and prevents Terminal)
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CCBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.ccbar.app</string>
    <key>CFBundleName</key>
    <string>CCBar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST_EOF

# Step 3: Configure Claude Code hooks
echo "Configuring Claude Code hooks..."
mkdir -p "$HOME/.claude"

# Hook definitions — stdin pipe for events that carry tool/session data,
# bare @- for events that already arrive as JSON on stdin.
HOOK_PIPE='input=$(cat); echo "$input" | curl -s -X POST -H "Content-Type: application/json" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0'
HOOK_BARE='curl -s -X POST -H "Content-Type: application/json" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0'

# Create or merge settings.json
if [ -f "$SETTINGS_FILE" ]; then
    # Check if hooks already configured
    if grep -q "localhost:27182" "$SETTINGS_FILE" 2>/dev/null; then
        echo "Hooks already configured in $SETTINGS_FILE"
    else
        echo "Merging hooks into existing $SETTINGS_FILE..."
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup"

        # Use python3 to merge JSON (available on macOS)
        python3 -c "
import json, os

settings_file = os.path.expanduser('~/.claude/settings.json')

with open(settings_file, 'r') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})

pipe_cmd = 'input=\$(cat); echo \"\$input\" | curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0'
bare_cmd = 'curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0'

hook_defs = {
    'Stop':              {'matcher': '*',                'command': bare_cmd},
    'PreToolUse':        {'matcher': 'AskUserQuestion',  'command': pipe_cmd},
    'PostToolUse':       {'matcher': '*',                'command': pipe_cmd},
    'Notification':      {'matcher': '*',                'command': pipe_cmd},
    'UserPromptSubmit':  {'matcher': '*',                'command': bare_cmd},
    'SessionEnd':        {'matcher': '*',                'command': bare_cmd},
}

for event_name, defn in hook_defs.items():
    entry = {
        'matcher': defn['matcher'],
        'hooks': [{'type': 'command', 'command': defn['command'], 'timeout': 3}]
    }
    hooks.setdefault(event_name, []).append(entry)

settings['hooks'] = hooks

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
"
        echo "Hooks merged. Backup at $SETTINGS_FILE.backup"
    fi
else
    # Create new settings.json
    cat > "$SETTINGS_FILE" << 'SETTINGS_EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST -H \"Content-Type: application/json\" -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
    echo "Created $SETTINGS_FILE with hooks"
fi

echo ""
echo "=== Installation Complete ==="
echo "App: $APP_DIR"
echo ""
echo "To start: open $APP_DIR"
echo "To auto-start on login: add CCBar.app to System Settings > General > Login Items"
echo ""
echo "NOTE: Restart any running Claude Code sessions for hooks to take effect."
