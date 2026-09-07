#!/usr/bin/env bash
# Install the NetBird promptless-sudo drop-in for the omarchy-netbird bar widget.
#
# Usage:  ./contrib/install-sudoers.sh [username]
#         (username defaults to the current user)
set -euo pipefail

USER_NAME="${1:-${SUDO_USER:-$USER}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/netbird-nopasswd.sudoers"
DEST="/etc/sudoers.d/49-netbird-nopasswd"

# The username is substituted into a sudoers file, so it must be a plain
# account name — never arbitrary text that could smuggle in extra directives.
if [[ ! $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Refusing to use '$USER_NAME' as a username: unexpected characters." >&2
  exit 1
fi
if ! id -u -- "$USER_NAME" >/dev/null 2>&1; then
  echo "No such user: $USER_NAME" >&2
  exit 1
fi

NB_PATH="$(command -v netbird || true)"
if [[ -z "$NB_PATH" ]]; then
  echo "netbird not found on PATH — install it first (e.g. 'omarchy pkg aur add netbird-bin')." >&2
  exit 1
fi
case "$NB_PATH" in
  /*[!a-zA-Z0-9/._-]*) echo "Refusing unusual netbird path: $NB_PATH" >&2; exit 1 ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Personalise: username + actual netbird path.
sed -e "s|^YOUR_USERNAME |${USER_NAME} |" \
    -e "s|/usr/bin/netbird|${NB_PATH}|g" \
    "$SRC" > "$tmp"

echo "About to install the following to $DEST:"
echo "------------------------------------------------------------"
cat "$tmp"
echo "------------------------------------------------------------"

# Syntax-check before it goes anywhere near /etc.
visudo -cqf "$tmp"

sudo install -m 0440 -o root -g root "$tmp" "$DEST"
sudo visudo -cqf "$DEST"

echo "Installed. Test with:  sudo -n ${NB_PATH} status --json | head -c 80"
