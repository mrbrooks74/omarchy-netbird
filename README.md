# omarchy-netbird

A [NetBird](https://netbird.io) status widget for the [Omarchy](https://omarchy.org)
shell bar (Quickshell). Shows connection state and peer count at a glance, and
gives you one-click connect / disconnect.

| State | Icon | Meaning |
|-------|------|---------|
| Connected |  (lock) | management + signal both up; shows `connected/total` peers |
| Disconnected |  (open lock) | daemon running, not connected |
| Working |  (hourglass, pulsing) | an `up`/`down` is in flight |
| Problem |  (triangle, urgent colour) | no sudo access, daemon down, or a management/signal error |

**Interactions** (same layout as `omarchy.tailscale`)

- **Left click** — open the **peer-list popup** (see below)
- **Right click** — connect if down, disconnect if up (`netbird up` / `netbird down`)
- **Middle click** — refresh now (quick icon blink to acknowledge)
- **Hover** — tooltip with IP, FQDN, peer count + P2P/relayed mix, average/max
  latency, total transfer, management/signal state, daemon version, and SSO
  session expiry

When the SSO session is within the warning window (default 24 h) or already
expired, the icon turns the theme's urgent colour.

### Peer-list popup

Left-click opens a themed panel anchored to the widget:

- **Header** — connection state, your FQDN and NetBird IP (click either to
  copy), `mgmt`/`signal` state, peer count, daemon version, and the SSO
  session-expiry line
- **Peer list** — scrollable; per peer: status dot (green / amber / grey),
  short name, NetBird IP, `P2P` or `relay` badge, and latency.
  - **Click a row** → copy that peer's IP (`wl-copy`)
  - **Hover a peer → `ssh`** → opens a terminal SSH'd to it. Default is plain
    `ssh <peer NetBird IP>`; set `sshMode: "netbird"` for `netbird ssh`.
    Prefixes `sshUser@` if set; tiled unless `floatingTerminal`.
- **Footer** — Connect/Disconnect · Refresh · Dashboard (or Status ▸) ·
  Re-login (only while the session is expiring/expired)

---

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`), plugin schema v1
- A NetBird account (or a self-hosted control plane)

The NetBird **client, service and sudo access are set up for you** on first
run — see below.

---

## Install

```bash
omarchy plugin add https://github.com/mrbrooks74/omarchy-netbird.git --enable --yes
```

That clones the plugin and enables it; the widget appears in the bar's right
section. (Drop `--enable --yes` if you'd rather read the code first, then
`omarchy plugin enable plugin.netbird`.)

### First run — click the wrench

Until NetBird is ready the widget shows a **wrench** icon.
**Left-click it** — a terminal opens and [`setup.sh`](setup.sh) runs:

1. installs the client — `omarchy pkg aur add netbird-bin`
2. installs and starts NetBird's own `netbird.service` (on the default
   socket; the AUR package only ships a templated `netbird@.service` the CLI
   can't find)
3. installs a `sudoers` drop-in so the widget can poll/toggle without a
   password prompt (`/etc/sudoers.d/49-netbird-nopasswd`, `netbird
   status`/`up`/`down` only — see [`contrib/`](contrib/))
4. runs `netbird up` (opens your browser for SSO login)

It's idempotent — re-running it (or clicking the wrench again) only does
what's missing. The widget switches to the normal icon within a few seconds
of setup finishing.

Prefer to do it by hand? Run `~/.config/omarchy/plugins/plugin.netbird/setup.sh`
yourself, or follow the four steps above. If you expose the daemon socket to a
group instead of using sudoers, set **`useSudo`** to `false` in the widget
settings.

### Move it

```bash
omarchy bar move plugin.netbird --section right   # or left / center
```

### Hacking on it

```bash
git clone https://github.com/mrbrooks74/omarchy-netbird.git \
  ~/.config/omarchy/plugins/plugin.netbird
```

Only **`omarchy restart shell`** reloads changed plugin QML (`rescanPlugins`
and the file watcher pick up new/removed plugins, not edited `.qml`).
Validate the manifest with `omarchy plugin validate <dir>`.

### Uninstall

Remove just the bar widget:

```bash
omarchy plugin remove plugin.netbird
```

To also undo what `setup.sh` did to the system, run
[`contrib/uninstall.sh`](contrib/uninstall.sh) **before** removing the plugin:

```bash
~/.config/omarchy/plugins/plugin.netbird/contrib/uninstall.sh          # deregister peer, remove service + sudoers; keep the client
~/.config/omarchy/plugins/plugin.netbird/contrib/uninstall.sh --purge  # also remove netbird-bin and wipe config/state
```

It runs `netbird deregister` first — otherwise the peer lingers in your
NetBird tenant as an offline entry and a later `netbird up` enrols a fresh
one, so the peer count creeps up on every reinstall.

---

## Settings

Configured per-widget in `~/.config/omarchy/shell.json` (or via Setup →
Plugins). Keys and defaults:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `refreshIntervalSec` | integer | `5` | How often to poll `netbird status` |
| `useSudo` | boolean | `true` | Prefix `netbird` calls with `sudo -n` |
| `showPeerCount` | boolean | `true` | Show `connected/total` next to the icon when connected |
| `dashboardUrl` | string | `""` | Right-click opens this URL; blank opens a status terminal |
| `sessionWarnHours` | integer | `24` | Warn (urgent icon + tooltip) when the SSO session expires within N hours; `0` disables |
| `sshUser` | string | `""` | Username for the per-peer SSH action (blank = current user) |
| `sshMode` | string | `"ssh"` | `"ssh"` = plain OpenSSH to the peer's NetBird IP (your key + the peer's `sshd`); `"netbird"` = `netbird ssh` (NetBird's own SSH server, needs it enabled on the peer + SSO) |
| `sshFlags` | string | `""` | Extra flags for the ssh command (syntax matches `sshMode`: OpenSSH `-o ...` vs. `netbird ssh -...`) |
| `floatingTerminal` | boolean | `false` | Open status / ssh / login in a floating presentation terminal instead of a normal tiled window |

Example layout entry:

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "plugin.netbird", "settings": { "refreshIntervalSec": 10, "dashboardUrl": "https://netbird.example.com" } },
        { "id": "omarchy.clock" }
      ]
    }
  }
}
```

---

## How it works

- Pure `QtQuick` + `Quickshell` + `Quickshell.Io` — no imports from
  Omarchy-internal QML modules, so it should survive shell updates. The bar host injects `bar`,
  `moduleName` and `settings` after load (documented in
  `$OMARCHY_PATH/shell/plugins/bar/README.md`).
- `netbird status --json` is parsed defensively: it handles both the newer
  `peers: { connected, total }` object and the older `peers: [ … ]` array,
  and both `management.connected` booleans and `state` strings.
- A short "settle" timer re-polls a few times right after a toggle so the
  icon catches up quickly instead of waiting a full interval.

---

## Security note

Omarchy plugins run as **unsandboxed code inside the long-lived
`omarchy-shell` process**. Worth reading before you enable it:
`NetbirdWidget.qml` (the widget), `setup.sh` / `contrib/uninstall.sh` (the
installer / uninstaller, which use `sudo`), and
`contrib/netbird-nopasswd.sudoers` (the privilege grant).

The widget's own external calls are `command -v netbird`,
`netbird status --json`, `netbird up` / `down` / `login` / `ssh`, `ssh`,
`wl-copy`, `xdg-open <your url>`, `omarchy-launch-tui` (or
`omarchy-launch-floating-terminal-with-presentation` when `floatingTerminal`),
and — only when you click the wrench — `bash setup.sh`.

**What the sudoers drop-in grants.** Exactly four commands, no wildcards:

```
netbird status        netbird status --json        netbird up        netbird down
```

Nothing else runs as root without a password. `login`, `ssh`, `service` and
friends go through interactive `sudo` in a terminal. A `*` wildcard here would
be a privilege-escalation surface — `netbird status` accepts `--log-file`,
`--config` and `--daemon-addr`, so "any flags as root" is not a safe grant.
If you installed a build before v0.5.1, re-run `setup.sh`: it detects the old
over-broad rule and replaces it.

**Values from the management server are treated as untrusted.** Peer names and
IPs are shell-quoted before they reach any command line, and every label is
rendered as `Text.PlainText` so a crafted peer name can't inject markup.
`sshFlags` is the one deliberately unquoted value — it's your own local config
and is meant to expand into several shell words.

---

## Roadmap

- Exit-node awareness / picker
- State-change desktop notifications (`notify-send`)
- `--daemon-addr` setting for the templated `netbird@` service
- Vertical-bar layout polish

Done: one-click first-run setup (wrench → `setup.sh`), peer-list popup
(copy IP, per-peer `ssh`, copy own IP/FQDN), richer tooltip (peer mix,
latency, transfer), SSO session-expiry warning.

---

## License

MIT — see [LICENSE](LICENSE).
