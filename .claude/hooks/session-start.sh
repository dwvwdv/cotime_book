#!/bin/bash
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Keep in step with `flutter-version` in .github/workflows/*.yml: a different
# SDK reports different lints, so analyze would be clean here and red in CI.
FLUTTER_VERSION="3.32.4"
FLUTTER_DIR="$HOME/flutter"

# Install Flutter if not already present, or reinstall if the pinned version
# changed (a reused home dir may carry a stale SDK).
needs_install=false
if [ ! -f "$FLUTTER_DIR/bin/flutter" ]; then
  needs_install=true
elif ! "$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | grep -q "Flutter $FLUTTER_VERSION "; then
  echo "Flutter version mismatch, reinstalling $FLUTTER_VERSION..."
  rm -rf "$FLUTTER_DIR"
  needs_install=true
fi

if [ "$needs_install" = true ]; then
  echo "Installing Flutter $FLUTTER_VERSION..."
  curl -fsSL \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar xJ -C "$HOME"
  # Allow git to operate in Flutter's directory (needed when running as root)
  git config --global --add safe.directory "$FLUTTER_DIR"
  echo "Flutter installed."
fi

# Persist Flutter in PATH for the session
echo "export PATH=\"$FLUTTER_DIR/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
export PATH="$FLUTTER_DIR/bin:$PATH"

flutter config --no-analytics 2>/dev/null || true

cd "$CLAUDE_PROJECT_DIR"
flutter pub get
