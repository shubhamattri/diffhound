#!/bin/bash
# diffhound installer
# Usage: curl -fsSL https://raw.githubusercontent.com/shubhamattri/diffhound/main/install.sh | bash

set -euo pipefail

REPO="shubhamattri/diffhound"
INSTALL_DIR="${DIFFHOUND_INSTALL_DIR:-$HOME/.diffhound}"
BIN_DIR="${HOME}/.local/bin"

echo ""
echo "  🐕 diffhound installer"
echo "  ──────────────────────────"
echo ""

# Check dependencies
missing=()
command -v gh >/dev/null 2>&1 || missing+=("gh")
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v claude >/dev/null 2>&1 || missing+=("claude")

if [ "$(uname -s)" = "Darwin" ]; then
  command -v gtimeout >/dev/null 2>&1 || missing+=("coreutils (gtimeout)")
  command -v gawk >/dev/null 2>&1 || missing+=("gawk")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "  Missing dependencies:"
  for dep in "${missing[@]}"; do
    echo "    - $dep"
  done
  echo ""
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "  Install with: brew install ${missing[*]}"
  else
    echo "  Install with your package manager"
  fi
  echo ""
  read -p "  Continue anyway? (y/n) " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Clone or update
if [ -d "$INSTALL_DIR" ]; then
  echo "  Updating existing installation..."
  cd "$INSTALL_DIR" && git pull --quiet
else
  echo "  Installing to $INSTALL_DIR..."
  git clone --quiet "https://github.com/${REPO}.git" "$INSTALL_DIR"
fi

# Symlink to PATH
mkdir -p "$BIN_DIR"
ln -sf "${INSTALL_DIR}/bin/diffhound" "${BIN_DIR}/diffhound"

# Verify
if command -v diffhound >/dev/null 2>&1; then
  echo ""
  echo "  ✓ Installed successfully"
  echo "  Usage: diffhound <PR_NUMBER> [--auto-post] [--fast]"
else
  echo ""
  echo "  ✓ Installed to ${BIN_DIR}/diffhound"
  echo ""
  echo "  Add to your PATH if not already:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  echo "  Then: diffhound <PR_NUMBER> [--auto-post] [--fast]"
fi

echo ""
echo "  Configure (add to ~/.zshrc or ~/.bashrc):"
echo "    export REVIEW_REPO_PATH=\"/path/to/your/repo\""
echo "    export REVIEW_LOGIN=\"your-github-username\""
echo ""
