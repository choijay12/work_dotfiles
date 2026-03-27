#!/bin/bash
# gce-install.sh — installs `gce` as a global command
# Run: bash gce-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"

echo "═══════════════════════════════════════════════════"
echo "  GCE — Gemini Context Engineer  (install)"
echo "═══════════════════════════════════════════════════"
echo ""

# Prerequisites
echo "🔍 Checking prerequisites..."
MISSING=""
command -v python3 >/dev/null 2>&1 || MISSING="$MISSING python3"
command -v gemini  >/dev/null 2>&1 || {
  echo "  ⚠  gemini not found — install after setup:"
  echo "     npm install -g @google/gemini-cli && gemini"
}
command -v claude  >/dev/null 2>&1 || {
  echo "  ⚠  claude not found — install after setup:"
  echo "     npm install -g @anthropic-ai/claude-code"
}
if [ -n "$MISSING" ]; then
  echo "  ✗ Missing required:$MISSING"
  echo "    Install python3 first, then re-run this script."
  exit 1
fi
echo "  ✅ python3 found: $(python3 --version)"

# Install PDF extraction tool (optional)
if command -v brew >/dev/null 2>&1 && ! command -v pdftotext >/dev/null 2>&1; then
  echo ""
  echo "💡 Optional: install pdftotext for PDF support?"
  read -r -p "  brew install poppler? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] && brew install poppler
elif command -v apt >/dev/null 2>&1 && ! command -v pdftotext >/dev/null 2>&1; then
  echo ""
  echo "💡 Optional: install pdftotext for PDF support?"
  read -r -p "  apt install poppler-utils? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] && sudo apt install -y poppler-utils
fi

# Create install dir
mkdir -p "$INSTALL_DIR"

# Copy gce.py
cp "$SCRIPT_DIR/gce.py" "$INSTALL_DIR/gce.py"
chmod +x "$INSTALL_DIR/gce.py"

# Create wrapper shim
cat > "$INSTALL_DIR/gce" << 'EOF'
#!/bin/bash
exec python3 "$(dirname "$0")/gce.py" "$@"
EOF
chmod +x "$INSTALL_DIR/gce"

echo ""
echo "  ✅ Installed to $INSTALL_DIR/gce"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo ""
  echo "⚠️  Add to your shell profile (~/.bashrc or ~/.zshrc):"
  echo '   export PATH="$HOME/.local/bin:$PATH"'
  echo ""
  echo "   Then reload: source ~/.bashrc  (or source ~/.zshrc)"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ Done! Usage:"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  gce \"add auth to my express app\""
echo "  gce --read src/ \"summarize the codebase\""
echo "  gce --pdf spec.pdf \"implement the /users endpoint\""
echo "  gce --interactive               (REPL mode)"
echo "  gce --interactive --read src/   (REPL + preloaded codebase)"
echo "  gce --gemini-only \"what is this repo about?\""
echo ""
echo "  Model auto-selection:"
echo "  • Haiku → simple/quick tasks (explain, rename, list...)"
echo "  • Sonnet → complex tasks (implement, refactor, debug...)"
echo "  • Override: gce --model opus \"design the architecture\""
echo ""
