#!/usr/bin/env bash
# One-shot setup for the omarchy-netbird bar widget.
#
# Run from the widget (click the wrench) or by hand:
#   bash ~/.config/omarchy/plugins/plugin.netbird/setup.sh
#
# Idempotent — safe to re-run. Needs an interactive terminal (sudo prompt,
# AUR build, browser SSO).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m%s\033[0m\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }

# True when sudo would run this command with no password prompt.
sudo_allows() {
  local err
  err="$(sudo -n "$@" 2>&1 >/dev/null || true)"
  [[ "$err" != *"password is required"* && "$err" != *"not allowed"* ]]
}

# Rev 1 of the drop-in granted `netbird status *` (any flags as root).
# Detect that by probing a flag the tightened rev-2 rule refuses.
sudoers_too_broad() {
  command -v netbird >/dev/null 2>&1 && sudo_allows netbird status --log-file /dev/null
}

echo "omarchy-netbird setup"
echo "---------------------"

# Already fully working *and* correctly scoped? Nothing to do.
if command -v netbird >/dev/null 2>&1 \
   && sudo -n netbird status --json 2>/dev/null | grep -q '"management"' \
   && ! sudoers_too_broad; then
  ok "NetBird is already installed, running and reachable without a password."
  echo
  echo "The bar widget should already show a lock. Done."
  exit 0
fi

# 1. Client -----------------------------------------------------------------
if command -v netbird >/dev/null 2>&1; then
  ok "netbird client present ($(netbird version 2>/dev/null | head -1))"
else
  step "Installing the NetBird client (AUR: netbird-bin)"
  omarchy pkg aur add netbird-bin
fi

# 2. Service on the DEFAULT socket ---------------------------------------
# The AUR package only ships a templated netbird@.service on a socket the
# plain CLI can't find; `netbird service install` writes a normal
# /etc/systemd/system/netbird.service on the default socket.
if systemctl show -p FragmentPath netbird.service 2>/dev/null | grep -q '=.\+'; then
  ok "netbird.service already installed"
else
  step "Installing the netbird system service"
  sudo netbird service install
fi

step "Starting the netbird service"
sudo systemctl enable --now netbird 2>/dev/null || sudo netbird service start || true

# 3. Promptless sudo for the widget -----------------------------------
# Scoped to exactly `netbird status [--json]`, `netbird up`, `netbird down`.
if sudoers_too_broad; then
  step "Replacing an over-broad sudoers drop-in (old rev allowed 'netbird status' with any flags)"
  warn "this tightens it to the exact commands the widget runs"
  "$HERE/contrib/install-sudoers.sh"
elif [[ -f /etc/sudoers.d/49-netbird-nopasswd ]] && sudo_allows netbird status --json; then
  ok "sudoers drop-in already installed and correctly scoped"
else
  step "Installing the sudoers drop-in (lets the widget poll/toggle without a password)"
  "$HERE/contrib/install-sudoers.sh"
fi

# 4. Connect ----------------------------------------------------------
if sudo -n netbird status --json 2>/dev/null | grep -q '"connected": *true'; then
  ok "NetBird already connected"
else
  step "Connecting (a browser window will open for SSO login)"
  sudo netbird up || true
fi

echo
ok "Setup complete."
echo "The bar widget will switch from the wrench to the normal icon within a few seconds."
