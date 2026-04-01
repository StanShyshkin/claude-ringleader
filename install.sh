#!/usr/bin/env bash
set -euo pipefail

# install.sh -- One-command installer for claude-ringleader
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/USER/claude-ringleader/main/install.sh | bash
#   # or
#   bash install.sh

INSTALL_DIR="${HOME}/.claude-ringleader"
REPO_URL="${CLAUDE_RINGLEADER_REPO:-https://github.com/StanShyshkin/claude-ringleader.git}"

echo "Installing claude-ringleader..."

# Clone or update
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Updating existing installation at ${INSTALL_DIR}..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "Cloning to ${INSTALL_DIR}..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# Detect shell profile
SHELL_PROFILE=""
if [[ -f "${HOME}/.zshrc" ]]; then
    SHELL_PROFILE="${HOME}/.zshrc"
elif [[ -f "${HOME}/.bashrc" ]]; then
    SHELL_PROFILE="${HOME}/.bashrc"
elif [[ -f "${HOME}/.bash_profile" ]]; then
    SHELL_PROFILE="${HOME}/.bash_profile"
fi

# Add to PATH if not already present
PATH_LINE="export PATH=\"\$HOME/.claude-ringleader/bin:\$PATH\""
if [[ -n "$SHELL_PROFILE" ]]; then
    if ! grep -qF '.claude-ringleader/bin' "$SHELL_PROFILE" 2>/dev/null; then
        echo "" >> "$SHELL_PROFILE"
        echo "# claude-ringleader orchestration scripts" >> "$SHELL_PROFILE"
        echo "$PATH_LINE" >> "$SHELL_PROFILE"
        echo "Added to PATH via ${SHELL_PROFILE}"
    else
        echo "PATH already configured in ${SHELL_PROFILE}"
    fi
else
    echo "Could not detect shell profile. Add this to your shell config manually:"
    echo "  ${PATH_LINE}"
fi

# Add reference to global CLAUDE.md
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
REFERENCE_LINE="For delegating tasks to Codex or Gemini, see ~/.claude-ringleader/CLAUDE.md and use scripts in ~/.claude-ringleader/bin/"
mkdir -p "${HOME}/.claude"
if [[ -f "$CLAUDE_MD" ]]; then
    if ! grep -qF 'claude-ringleader' "$CLAUDE_MD" 2>/dev/null; then
        echo "" >> "$CLAUDE_MD"
        echo "$REFERENCE_LINE" >> "$CLAUDE_MD"
        echo "Added reference to ${CLAUDE_MD}"
    else
        echo "Reference already in ${CLAUDE_MD}"
    fi
else
    echo "$REFERENCE_LINE" > "$CLAUDE_MD"
    echo "Created ${CLAUDE_MD}"
fi

echo ""
echo "Done! Restart your shell or run:"
echo "  source ${SHELL_PROFILE:-your-shell-profile}"
echo ""
echo "Then use from any project:"
echo "  delegate.sh -d . \"your task\""
