#!/usr/bin/env bash
# Cleanly reverse setup.sh for the omarchy-netbird bar widget.
#
#   bash contrib/uninstall.sh            # deregister this peer, remove the
#                                        # service + sudoers drop-in; keep the
#                                        # netbird client installed
#   bash contrib/uninstall.sh --purge    # also remove netbird-bin and wipe
#                                        # /etc/netbird + /var/lib/netbird
#
# Deregistering matters: if you just delete /var/lib/netbird the peer keeps
# lingering in your NetBird tenant as an offline entry, and a fresh `netbird up`
# enrols a brand-new one — so the peer count creeps up every rebuild.
#
# This does NOT remove the bar widget itself:
#   omarchy plugin remove plugin.netbird
set -euo pipefail

PURGE=0
case "${1:-}" in
  "")        ;;
  --purge)   PURGE=1 ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m%s\033[0m\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }

if ! command -v netbird >/dev/null 2>&1 \
   && ! sudo -n test -f /etc/sudoers.d/49-netbird-nopasswd 2>/dev/null \
   && [[ ! -e /etc/systemd/system/netbird.service ]]; then
  ok "Nothing to do — netbird client, service and sudoers drop-in are already gone."
  exit 0
fi

if (( PURGE )); then
  echo "This will deregister this machine from NetBird, remove the netbird"
  echo "client, and delete /etc/netbird and /var/lib/netbird."
  read -r -p "Continue? [y/N] " reply
  [[ $reply == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

# 1. Deregister this peer so it doesn't linger in your tenant.
if command -v netbird >/dev/null 2>&1; then
  step "Disconnecting and deregistering this peer"
  sudo netbird down 2>/dev/null || true
  if sudo netbird deregister 2>/dev/null; then
    ok "peer deregistered from the management server"
  else
    warn "deregister failed (already gone, or not logged in)."
    warn "If it still shows up, delete it in the NetBird dashboard -> Peers."
  fi
fi

# 2. Remove the service that `netbird service install` created.
step "Removing the netbird service"
sudo systemctl disable --now netbird 2>/dev/null || true
command -v netbird >/dev/null 2>&1 && { sudo netbird service uninstall 2>/dev/null || true; }
sudo rm -f /etc/systemd/system/netbird.service \
           /etc/systemd/system/multi-user.target.wants/netbird.service
sudo systemctl daemon-reload 2>/dev/null || true

# 3. Remove the promptless-sudo drop-in.
if sudo test -f /etc/sudoers.d/49-netbird-nopasswd; then
  step "Removing the sudoers drop-in"
  sudo rm -f /etc/sudoers.d/49-netbird-nopasswd
  ok "removed /etc/sudoers.d/49-netbird-nopasswd"
fi

# 4. Purge: client package + config/state.
if (( PURGE )); then
  step "Removing the netbird client package"
  sudo pacman -R --noconfirm netbird-bin-debug netbird-bin 2>/dev/null \
    || sudo pacman -R --noconfirm netbird-bin 2>/dev/null || true
  step "Deleting config and state"
  sudo rm -rf /etc/netbird /var/lib/netbird /var/log/netbird /var/run/netbird
fi

echo
ok "Done."
(( PURGE )) || echo "The netbird client is still installed — re-run with --purge to remove it."
echo "To remove the bar widget:  omarchy plugin remove plugin.netbird"
