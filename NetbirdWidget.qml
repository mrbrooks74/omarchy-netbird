// NetBird bar widget for the Omarchy shell.
//
// Contract (see $OMARCHY_PATH/shell/plugins/bar/README.md + Ui/WidgetButton.qml):
// the bar host injects `bar`, `moduleName` and `settings` after load.
//
//  - Left-click: the bar keeps a click-target registry. We register with it
//    and expose `interactive` / `pressable` / `concealed` / `tooltipHovered`
//    and a `triggerPress(button)` function; the bar calls that for left-clicks
//    it catches under its drag handler.
//  - Middle / right-click: the bar's drag MouseArea sits on top and only
//    accepts LeftButton, so those never reach a child MouseArea. This MouseArea
//    (under it) still gets them on fall-through.
//  - Hover / tooltip: `bar.showTooltip(target, text)` only fires when
//    `target.tooltipHovered === true`, so we expose that, driven by a
//    hover-only MouseArea.
//
// Pure QtQuick + Quickshell + Quickshell.Io — no Omarchy-internal QML imports.
//
// Data source: `netbird status --json`. Toggle: `netbird up` / `netbird down`.
// The daemon socket is root-owned, so both run through `sudo -n` by default
// (install contrib/netbird-nopasswd.sudoers to make that promptless).

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // ---- injected by the bar host --------------------------------------
    property var bar: null
    property string moduleName: "plugin.netbird"
    property var settings: ({})

    // ---- click-target contract (read by the bar's registry) ----------
    property bool interactive: true
    property bool pressable: true
    property bool concealed: false
    readonly property bool tooltipHovered: mouseArea.containsMouse && interactive && !concealed && visible
    property var registeredBar: null

    function syncClickRegistration() {
        if (registeredBar && registeredBar.unregisterClickTarget)
            registeredBar.unregisterClickTarget(root)
        registeredBar = bar
        if (registeredBar && registeredBar.registerClickTarget)
            registeredBar.registerClickTarget(root)
    }

    // Interaction model (matches omarchy.tailscale):
    //   left  = peer-list popup   (or run setup when NetBird isn't ready)
    //   right = connect / disconnect
    //   middle = refresh
    function triggerPress(button) {
        if (bar && bar.hideTooltip) bar.hideTooltip(root)
        if (button === Qt.RightButton) toggle()
        else if (button === Qt.MiddleButton) { flash(); refresh() }
        else if (needsSetup) runSetup()
        else togglePopup()
    }

    // Open a terminal that runs the bundled setup.sh (installs the client +
    // service + sudoers drop-in, then `netbird up`). Path is resolved relative
    // to this QML file so it works wherever the plugin is checked out.
    function runSetup() {
        // resolvedUrl() percent-encodes; decode so paths with spaces work.
        var s = decodeURIComponent(String(Qt.resolvedUrl("setup.sh")).replace(/^file:\/\//, ""))
        term("bash " + shq(s))
    }

    // ---- popup lifecycle -------------------------------------------
    // The bar keeps one popout at a time; it calls close() on us when another
    // widget's popup opens, and draws the "panel open" dot under us while
    // activePopout === root.
    property bool popupOpen: false
    readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null

    function openPopup() {
        if (!barWindow) return
        refresh()
        popupOpen = true
        if (bar && bar.requestPopout) bar.requestPopout(root)
    }
    function close() {                    // bar calls this on popout switch
        popupOpen = false
        if (bar && bar.releasePopout) bar.releasePopout(root)
    }
    function togglePopup() { popupOpen ? close() : openPopup() }

    onBarChanged: syncClickRegistration()
    Component.onCompleted: {
        syncClickRegistration()
        whichProc.running = true
    }
    Component.onDestruction: {
        if (registeredBar && registeredBar.unregisterClickTarget)
            registeredBar.unregisterClickTarget(root)
    }

    // ---- settings ----------------------------------------------------
    function setting(key, fallback) {
        if (settings && settings[key] !== undefined && settings[key] !== null)
            return settings[key]
        return fallback
    }
    readonly property int refreshMs: Math.max(2, Number(setting("refreshIntervalSec", 5))) * 1000
    readonly property bool useSudo: setting("useSudo", true) === true
    readonly property bool showPeerCount: setting("showPeerCount", true) === true
    readonly property string dashboardUrl: String(setting("dashboardUrl", ""))
    readonly property double sessionWarnMs: Math.max(0, Number(setting("sessionWarnHours", 24))) * 3600000
    readonly property string sshUser: String(setting("sshUser", "")).trim()
    readonly property string sshMode: String(setting("sshMode", "ssh")).trim().toLowerCase()
    readonly property string sshFlags: String(setting("sshFlags", "")).trim()
    readonly property bool floatingTerminal: setting("floatingTerminal", false) === true
    // Advanced: override the command used to fetch status JSON — e.g. to target
    // the templated `netbird@` service's socket
    // (`sudo netbird status --json --daemon-addr unix:///var/run/netbird/default.sock`).
    // Blank = `[sudo -n] netbird status --json`.
    readonly property string statusCommand: String(setting("statusCommand", "")).trim()

    // ---- theme (with standalone fallbacks) --------------------------
    readonly property color fg: bar ? bar.foreground : "#e0e0e0"
    readonly property color urgentColor: bar ? bar.urgent : "#e06c75"
    readonly property color dim: Qt.darker(fg, 1.7)
    readonly property string fontFamily: bar ? bar.fontFamily : "monospace"
    readonly property int barSize: bar ? bar.barSize : 26

    // ---- state -----------------------------------------------------
    // connState: "connected" | "disconnected" | "connecting" | "error" | "unknown"
    property string connState: "unknown"
    property int peersConnected: 0
    property int peersTotal: 0
    property int peersP2P: 0
    property int peersRelayed: 0
    property var peerList: []             // [{name,ip,type,status,connected,latencyMs,handshakeAgo,rx,tx}]
    property real latencyAvgMs: 0
    property real latencyMaxMs: 0
    property double rxTotal: 0
    property double txTotal: 0
    property bool mgmtConnected: false
    property bool signalConnected: false
    property string myIp: ""
    property string fqdn: ""
    property string daemonVersion: ""
    property string lastError: ""
    property bool netbirdInstalled: true
    property bool pending: false          // a toggle is in flight
    property double pendingUntil: 0

    // SSO session expiry (epoch ms; 0 = unknown/none). sessionMsLeft is
    // recomputed on every poll so the derived flags stay fresh without a
    // live Date.now() binding.
    property double sessionExpiresMs: 0
    property double sessionMsLeft: -1
    readonly property bool sessionExpired: sessionExpiresMs > 0 && sessionMsLeft < 0
    readonly property bool sessionExpiringSoon: sessionMsLeft >= 0 && sessionWarnMs > 0 && sessionMsLeft < sessionWarnMs

    readonly property bool busy: pending || connState === "connecting"

    // Setup isn't done: client missing, or installed but the daemon/sudo path
    // isn't working. Left-click then runs setup.sh instead of the popup.
    readonly property bool needsSetup: !netbirdInstalled
        || (connState === "error"
            && (lastError.indexOf("sudo") !== -1 || lastError.indexOf("daemon") !== -1))

    // Nerd Font (Font Awesome) private-use glyphs, by codepoint so the source
    // stays plain ASCII: f0ad wrench, f252 hourglass-half, f023 lock,
    // f09c unlock-alt, f071 exclamation-triangle.
    readonly property string glyph: {
        if (needsSetup) return String.fromCharCode(0xf0ad)
        if (busy) return String.fromCharCode(0xf252)
        if (connState === "connected") return String.fromCharCode(0xf023)
        if (connState === "disconnected") return String.fromCharCode(0xf09c)
        return String.fromCharCode(0xf071)
    }
    readonly property color glyphColor: {
        if (needsSetup) return urgentColor
        if (busy) return fg
        if (connState === "connected")
            return (sessionExpired || sessionExpiringSoon) ? urgentColor : fg
        if (connState === "disconnected") return dim
        return urgentColor
    }
    readonly property string peerBadge: (showPeerCount && connState === "connected" && peersTotal > 0)
        ? (peersConnected + "/" + peersTotal) : ""

    readonly property string tooltipText: {
        var L = []
        if (needsSetup) {
            L.push(netbirdInstalled ? "NetBird — " + (lastError || "not reachable")
                                    : "NetBird — not installed")
            L.push("")
            L.push("Left-click to install & connect (opens a terminal)")
            return L.join("\n")
        }
        if (connState === "connected") L.push("NetBird — connected")
        else if (connState === "disconnected") L.push("NetBird — disconnected")
        else if (busy) L.push("NetBird — working…")
        else L.push("NetBird — " + (lastError !== "" ? lastError : "status unavailable"))

        if (myIp !== "") L.push("IP: " + myIp)
        if (fqdn !== "") L.push(fqdn)

        if (peersTotal > 0) {
            var mix = []
            if (peersP2P > 0) mix.push(peersP2P + " P2P")
            if (peersRelayed > 0) mix.push(peersRelayed + " relayed")
            L.push("Peers: " + peersConnected + "/" + peersTotal + " connected"
                 + (mix.length ? "  (" + mix.join(", ") + ")" : ""))
        }
        if (latencyAvgMs > 0)
            L.push("Latency: " + Math.round(latencyAvgMs) + " ms avg"
                 + (latencyMaxMs > latencyAvgMs + 0.5 ? "  ·  " + Math.round(latencyMaxMs) + " ms max" : ""))
        if (rxTotal + txTotal > 0)
            L.push("Transfer: ↓ " + fmtBytes(rxTotal) + "   ↑ " + fmtBytes(txTotal))

        L.push("mgmt " + (mgmtConnected ? "✓" : "✗")
             + "   signal " + (signalConnected ? "✓" : "✗")
             + (daemonVersion !== "" ? "   v" + daemonVersion : ""))

        if (sessionExpired)
            L.push("⚠ SSO session expired — open peers to re-login")
        else if (sessionExpiringSoon)
            L.push("⚠ Session expires in " + fmtDuration(sessionMsLeft) + " — re-login soon")
        else if (sessionMsLeft > 0)
            L.push("Session expires in " + fmtDuration(sessionMsLeft))

        L.push("")
        L.push("Left: peers  ·  Middle: refresh  ·  Right: "
             + (connState === "connected" ? "disconnect" : "connect"))
        return L.join("\n")
    }

    implicitWidth: contentRow.implicitWidth + 12
    implicitHeight: barSize
    visible: true

    // ---- helpers -------------------------------------------------
    function sudoPrefix() { return useSudo ? "sudo -n " : "" }

    function refresh() {
        if (!netbirdInstalled || statusProc.running) return
        statusProc.running = true
    }

    function flash() { flashAnim.restart() }

    function settlePending() {
        if (pending && Date.now() >= pendingUntil) pending = false
    }

    // Copy a value to the clipboard; the source element shows a brief
    // "copied" state (peer rows, own IP/FQDN in the header).
    property string copiedValue: ""
    function copyValue(v) {
        if (!v || !bar || !bar.run) return
        bar.run("wl-copy " + shq(v))
        copiedValue = v
        copiedResetTimer.restart()
    }
    Timer { id: copiedResetTimer; interval: 1400; onTriggered: root.copiedValue = "" }

    // Run `cmd` in a terminal. Tiled by default (app-id org.omarchy.netbird
    // isn't in Omarchy's float rule); floating + presentation wrapper when the
    // `floatingTerminal` setting is on. Always keeps the window open until a
    // keypress — `netbird` sub-commands frequently print an error and still
    // exit 0, so an exit-code check isn't reliable.
    function term(cmd) {
        if (!bar || !bar.run) return
        if (floatingTerminal) {
            bar.run("omarchy-launch-floating-terminal-with-presentation " + shq(cmd))
        } else {
            var inner = cmd + "; echo; read -n1 -s -r -p 'Press any key to close…'"
            bar.run("omarchy-launch-tui --app-id=org.omarchy.netbird bash -lc " + shq(inner))
        }
    }

    // Open an interactive `netbird ssh` session to a peer.
    // Open an SSH session to a peer. "ssh" mode = plain OpenSSH to the peer's
    // NetBird IP (your key + the peer's sshd); "netbird" mode = `netbird ssh`
    // (NetBird's own SSH server + SSO).
    function sshPeer(ip, name) {
        var target = sshMode === "netbird" ? (name || ip) : (ip || name)
        if (!target) return
        var host = sshUser !== "" ? sshUser + "@" + target : target
        var base = sshMode === "netbird" ? "netbird ssh" : "ssh"
        // `host` comes from the management server (peer fqdn / netbirdIp) and
        // ends up in a string the terminal's bash evaluates — it MUST be quoted.
        // `sshFlags` is deliberately left unquoted: it is local config that is
        // meant to expand into several shell words.
        term(base + (sshFlags !== "" ? " " + sshFlags : "") + " " + shq(host))
        close()
    }

    function fmtAgo(ms) {
        if (ms < 0) return ""
        var s = Math.floor(ms / 1000)
        if (s < 60) return s + "s ago"
        var m = Math.floor(s / 60)
        if (m < 60) return m + "m ago"
        var h = Math.floor(m / 60)
        if (h < 24) return h + "h ago"
        return Math.floor(h / 24) + "d ago"
    }

    function reLogin() {
        term("sudo netbird login")
        close()
    }

    function clearStats() {
        peersConnected = 0; peersTotal = 0; peersP2P = 0; peersRelayed = 0
        peerList = []
        latencyAvgMs = 0; latencyMaxMs = 0; rxTotal = 0; txTotal = 0
        sessionExpiresMs = 0; sessionMsLeft = -1
    }

    // strip the common ".netbird.cloud" suffix for display
    function shortName(fqdn) {
        return String(fqdn).replace(/\.netbird\.cloud$/, "")
    }

    // Single-quote for /bin/sh.
    function shq(s) {
        return "'" + String(s).split("'").join("'\\''") + "'"
    }

    function fmtBytes(n) {
        n = Number(n) || 0
        if (n < 1024) return n + " B"
        var u = ["KB", "MB", "GB", "TB"], i = -1
        do { n /= 1024; i++ } while (n >= 1024 && i < u.length - 1)
        return (n < 10 ? n.toFixed(1) : Math.round(n)) + " " + u[i]
    }

    function fmtDuration(ms) {
        var s = Math.floor(Math.max(0, ms) / 1000)
        if (s < 60) return s + "s"
        var m = Math.floor(s / 60)
        if (m < 60) return m + "m"
        var h = Math.floor(m / 60)
        if (h < 24) return h + "h " + (m % 60) + "m"
        return Math.floor(h / 24) + "d " + (h % 24) + "h"
    }

    function openDashboard() {
        if (bar && bar.run && dashboardUrl !== "") bar.run("xdg-open " + shq(dashboardUrl))
        close()
    }

    function openStatusTerminal() {
        term("sudo netbird status")
        close()
    }

    function applyStatus(raw) {
        var text = (raw || "").trim()
        if (text === "") {
            root.connState = "disconnected"
            root.mgmtConnected = false
            root.signalConnected = false
            root.clearStats()
            root.lastError = "daemon not responding"
            settlePending()
            return
        }

        var data = null
        try {
            data = JSON.parse(text)
        } catch (e) {
            var low = text.toLowerCase()
            root.mgmtConnected = false
            root.signalConnected = false
            root.clearStats()
            if (low.indexOf("permission denied") !== -1 || low.indexOf("a password is required") !== -1) {
                root.connState = "error"
                root.lastError = "no sudo access — install the sudoers drop-in"
            } else if (low.indexOf("connection refused") !== -1 || low.indexOf("daemon") !== -1
                    || low.indexOf("no such file") !== -1) {
                root.connState = "disconnected"
                root.lastError = "daemon not running"
            } else {
                root.connState = "error"
                root.lastError = text.split("\n")[0].slice(0, 120)
            }
            settlePending()
            return
        }

        // peers: newer builds -> object {connected,total,details}; older -> array
        var details = []
        var pc = 0, pt = 0
        if (data.peers && typeof data.peers === "object" && !Array.isArray(data.peers)) {
            pc = Number(data.peers.connected || 0)
            details = Array.isArray(data.peers.details) ? data.peers.details : []
            pt = Number(data.peers.total || details.length)
        } else if (Array.isArray(data.peers)) {
            details = data.peers
            pt = details.length
        }

        var p2p = 0, relayed = 0, latSum = 0, latN = 0, latMax = 0, rx = 0, tx = 0
        var list = []
        var nowMs = Date.now()
        for (var i = 0; i < details.length; i++) {
            var d = details[i]
            var stRaw = String(d.status || d.connectionStatus || "")
            var st = stRaw.toLowerCase()
            if (details === data.peers && st === "connected") pc++   // array shape: count here
            var ct = String(d.connectionType || d.connType || "")
            if (ct === "P2P") p2p++
            else if (ct === "Relayed") relayed++
            var latMs = Number(d.latency || 0) / 1e6
            if (latMs > 0) { latSum += latMs; latN++; if (latMs > latMax) latMax = latMs }
            var prx = Number(d.transferReceived || 0)
            var ptx = Number(d.transferSent || 0)
            rx += prx
            tx += ptx

            var hs = String(d.lastWireguardHandshake || "")
            var hsMs = (hs !== "" && hs.indexOf("0001-01-01") !== 0) ? Date.parse(hs) : NaN
            list.push({
                name: shortName(d.fqdn || d.netbirdIp || d.ip || "peer"),
                ip: String(d.netbirdIp || d.ip || ""),
                type: ct,
                status: stRaw,
                connected: st === "connected",
                latencyMs: latMs,
                handshakeAgo: isNaN(hsMs) ? -1 : Math.max(0, nowMs - hsMs),
                rx: prx, tx: ptx
            })
        }
        list.sort(function(a, b) {
            if (a.connected !== b.connected) return a.connected ? -1 : 1
            return a.name.localeCompare(b.name)
        })
        root.peerList = list
        root.peersConnected = pc
        root.peersTotal = pt
        root.peersP2P = p2p
        root.peersRelayed = relayed
        root.latencyAvgMs = latN > 0 ? latSum / latN : 0
        root.latencyMaxMs = latMax
        root.rxTotal = rx
        root.txTotal = tx

        // SSO session expiry (Go zero-time or "" means "no expiry")
        var se = String(data.sessionExpiresAt || data.sessionExpiresIn || "")
        root.sessionExpiresMs = 0
        if (se !== "" && se.indexOf("0001-01-01") !== 0) {
            var t = Date.parse(se)
            if (!isNaN(t)) root.sessionExpiresMs = t
        }
        root.sessionMsLeft = root.sessionExpiresMs > 0 ? root.sessionExpiresMs - Date.now() : -1

        var mgmt = data.management || data.managementState || {}
        var sig = data.signal || data.signalState || {}
        root.mgmtConnected = (mgmt.connected === true)
            || String(mgmt.state || "").toLowerCase() === "connected"
        root.signalConnected = (sig.connected === true)
            || String(sig.state || "").toLowerCase() === "connected"

        root.myIp = String(data.netbirdIp || data.ip || "").split("/")[0]  // drop CIDR suffix
        root.fqdn = String(data.fqdn || data.domain || "")
        root.daemonVersion = String(data.daemonVersion || data.daemon_version || "")

        var mgmtErr = String(mgmt.error || "")
        var sigErr = String(sig.error || "")
        if (root.mgmtConnected && root.signalConnected) {
            root.connState = "connected"
            root.lastError = ""
        } else if (mgmtErr !== "" || sigErr !== "") {
            root.connState = "error"
            root.lastError = mgmtErr || sigErr
        } else {
            root.connState = "disconnected"
        }
        settlePending()
    }

    function toggle() {
        if (!netbirdInstalled) return
        var action = (connState === "connected") ? "down" : "up"
        toggleProc.command = ["sh", "-c", sudoPrefix() + "netbird " + action]
        pending = true
        pendingUntil = Date.now() + 6000
        connState = "connecting"
        toggleProc.running = true
        settleTimer.ticks = 0
        settleTimer.restart()
    }

    // ---- processes ---------------------------------------------
    Process {
        id: whichProc
        command: ["sh", "-c", "command -v netbird >/dev/null 2>&1"]
        onExited: function(exitCode) {
            root.netbirdInstalled = (exitCode === 0)
            if (root.netbirdInstalled) root.refresh()
        }
    }

    Process {
        id: statusProc
        command: ["sh", "-c", root.statusCommand !== ""
            ? root.statusCommand
            : root.sudoPrefix() + "netbird status --json 2>&1"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyStatus(text)
        }
    }

    Process { id: toggleProc }

    Timer {
        id: settleTimer
        interval: 1200
        repeat: true
        running: false
        property int ticks: 0
        onTriggered: {
            ticks++
            root.refresh()
            if (ticks >= 5) { stop(); ticks = 0 }
        }
    }

    Timer {
        interval: root.refreshMs
        running: true
        repeat: true
        triggeredOnStart: false
        // While the client is missing, keep re-checking for it (cheap) so the
        // widget flips out of the setup state on its own after setup.sh runs.
        onTriggered: root.netbirdInstalled ? root.refresh()
                                           : (whichProc.running = true)
    }

    // ---- UI --------------------------------------------------
    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: 3

        Text {
            textFormat: Text.PlainText
            id: iconText
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            color: root.glyphColor
            font.family: root.fontFamily
            font.pixelSize: 13
            renderType: Text.NativeRendering
            Behavior on color { ColorAnimation { duration: 150 } }
        }

        Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.peerBadge !== ""
            text: root.peerBadge
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 11
        }
    }

    // Pulsing icon while a toggle is settling.
    SequentialAnimation {
        running: root.busy
        loops: Animation.Infinite
        alwaysRunToEnd: true
        onRunningChanged: if (!running) iconText.opacity = 1.0
        NumberAnimation { target: iconText; property: "opacity"; from: 1.0; to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
        NumberAnimation { target: iconText; property: "opacity"; from: 0.35; to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
    }

    // Quick blink to acknowledge a manual refresh (middle-click).
    SequentialAnimation {
        id: flashAnim
        running: false
        onRunningChanged: if (!running && !root.busy) contentRow.opacity = 1.0
        NumberAnimation { target: contentRow; property: "opacity"; from: 1.0; to: 0.25; duration: 90 }
        NumberAnimation { target: contentRow; property: "opacity"; from: 0.25; to: 1.0; duration: 160 }
    }

    // Same pattern as Ui/WidgetButton: a full MouseArea under the bar's
    // drag handler. The bar's drag MouseArea is on top and only accepts
    // LeftButton, so:
    //   - hover  -> reaches this MouseArea (drives tooltipHovered + tooltip)
    //   - middle/right press -> falls through to this MouseArea's onClicked
    //   - left  -> consumed by the bar, delivered to us via the click-target
    //     registry (triggerPress); never reaches onClicked here
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        hoverEnabled: true
        onEntered: if (root.bar && root.bar.showTooltip) root.bar.showTooltip(root, root.tooltipText)
        onExited: if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(root)
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) return  // handled via the registry
            root.triggerPress(mouse.button)
        }
    }

    // Keep the tooltip text current while the pointer stays on the widget.
    Connections {
        target: root
        function onTooltipTextChanged() {
            if (mouseArea.containsMouse && root.bar && root.bar.showTooltip)
                root.bar.showTooltip(root, root.tooltipText)
        }
    }

    // ---- peer-list popup -------------------------------------------
    component PopupButton: Item {
        id: pb
        property string label: ""
        property bool danger: false
        signal activated()
        visible: label !== ""
        implicitWidth: pbText.implicitWidth + 18
        implicitHeight: pbText.implicitHeight + 10
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: pbMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12) : "transparent"
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.20)
        }
        Text {
            textFormat: Text.PlainText
            id: pbText
            anchors.centerIn: parent
            text: pb.label
            color: pb.danger ? root.urgentColor : root.fg
            font.family: root.fontFamily
            font.pixelSize: 11
        }
        MouseArea {
            id: pbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pb.activated()
        }
    }

    PopupWindow {
        id: popup
        visible: root.popupOpen && root.barWindow !== null
        color: "transparent"
        implicitWidth: 328
        implicitHeight: Math.round(bodyCol.implicitHeight) + 24

        anchor {
            id: popupAnchor
            window: root.barWindow
            adjustment: PopupAdjustment.Slide
            edges: Edges.Top | Edges.Left
            gravity: Edges.Bottom | Edges.Right
            rect.width: 1
            rect.height: 1
            onAnchoring: {
                var bw = root.barWindow
                if (!bw || !bw.contentItem) return
                var pw = popup.implicitWidth
                var ph = popup.implicitHeight
                var pos = (root.bar && root.bar.position) ? root.bar.position : "top"
                var lx = root.width / 2 - pw / 2
                var ly = root.height + 8
                if (pos === "bottom") { ly = -ph - 8 }
                else if (pos === "left") { lx = root.width + 8; ly = root.height / 2 - ph / 2 }
                else if (pos === "right") { lx = -pw - 8; ly = root.height / 2 - ph / 2 }
                var p = bw.contentItem.mapFromItem(root, lx, ly)
                popupAnchor.rect.x = Math.round(p.x)
                popupAnchor.rect.y = Math.round(p.y)
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: root.bar ? root.bar.background : "#1e1e2e"
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

            // Esc closes when the popup has keyboard focus (compositor-dependent).
            focus: true
            Keys.onEscapePressed: root.close()

            Column {
                id: bodyCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                spacing: 8

                // --- header ---
                Row {
                    width: parent.width
                    spacing: 8
                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.glyph
                        color: root.glyphColor
                        font.family: root.fontFamily
                        font.pixelSize: 15
                    }
                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 30
                        text: root.connState === "connected" ? "NetBird — connected"
                            : root.connState === "disconnected" ? "NetBird — disconnected"
                            : root.busy ? "NetBird — working…"
                            : "NetBird — " + (root.lastError !== "" ? root.lastError : "unavailable")
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                }
                // own FQDN / IP — click either to copy
                Row {
                    width: parent.width
                    spacing: 12
                    visible: root.fqdn !== "" || root.myIp !== ""

                    Text {
                        textFormat: Text.PlainText
                        visible: root.fqdn !== ""
                        text: root.copiedValue === root.fqdn ? "copied ✓" : root.fqdn
                        color: root.copiedValue === root.fqdn ? "#22c55e"
                             : (fqdnMouse.containsMouse ? root.fg : root.dim)
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        MouseArea {
                            id: fqdnMouse
                            anchors.fill: parent
                            anchors.margins: -3
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyValue(root.fqdn)
                        }
                    }
                    Text {
                        textFormat: Text.PlainText
                        visible: root.myIp !== ""
                        text: root.copiedValue === root.myIp ? "copied ✓" : root.myIp
                        color: root.copiedValue === root.myIp ? "#22c55e"
                             : (ipMouse.containsMouse ? root.fg : root.dim)
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        MouseArea {
                            id: ipMouse
                            anchors.fill: parent
                            anchors.margins: -3
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyValue(root.myIp)
                        }
                    }
                }
                Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "mgmt " + (root.mgmtConnected ? "✓" : "✗")
                        + "   signal " + (root.signalConnected ? "✓" : "✗")
                        + "   " + root.peersConnected + "/" + root.peersTotal + " peers"
                        + (root.daemonVersion !== "" ? "   v" + root.daemonVersion : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }
                Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: root.sessionMsLeft > 0 || root.sessionExpired
                    text: root.sessionExpired ? "⚠ SSO session expired"
                        : (root.sessionExpiringSoon ? "⚠ " : "")
                          + "session expires in " + root.fmtDuration(root.sessionMsLeft)
                    color: (root.sessionExpiringSoon || root.sessionExpired) ? root.urgentColor : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }

                Rectangle {
                    width: parent.width; height: 1
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                }

                // --- peer list ---
                Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: root.peerList.length === 0
                    text: root.connState === "connected" ? "No peers." : "Not connected."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }

                ListView {
                    id: peerView
                    width: parent.width
                    visible: root.peerList.length > 0
                    height: visible ? Math.min(contentHeight, 264) : 0
                    clip: true
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.peerList
                    spacing: 2

                    delegate: Rectangle {
                        id: peerRow
                        width: peerView.width
                        height: 36
                        radius: 6
                        color: rowHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent"
                        readonly property bool showCopied: root.copiedValue === modelData.ip && modelData.ip !== ""

                        // HoverHandler keeps reporting hover even when a child
                        // MouseArea (the ssh hit-area) is under the pointer.
                        HoverHandler { id: rowHover }

                        // Background click target (declared first → sits under the
                        // per-action MouseAreas below).
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyValue(modelData.ip)
                        }

                        Rectangle {
                            id: dot
                            width: 8; height: 8; radius: 4
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            color: modelData.connected ? "#22c55e"
                                 : (String(modelData.status).toLowerCase() === "connecting"
                                    ? "#eab308" : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35))
                        }
                        Column {
                            anchors.left: dot.right
                            anchors.leftMargin: 8
                            anchors.right: rightInfo.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                textFormat: Text.PlainText
                                width: parent.width
                                text: modelData.name
                                color: root.fg
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Text {
                                textFormat: Text.PlainText
                                width: parent.width
                                text: modelData.ip
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Row {
                            id: rightInfo
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            Text {
                                textFormat: Text.PlainText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: peerRow.showCopied
                                text: "copied ✓"
                                color: "#22c55e"
                                font.family: root.fontFamily
                                font.pixelSize: 10
                            }
                            // ssh action — appears on hover for reachable peers
                            Text {
                                textFormat: Text.PlainText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !peerRow.showCopied && rowHover.hovered && modelData.ip !== ""
                                text: "ssh"
                                color: sshMouse.containsMouse ? root.fg : root.dim
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                MouseArea {
                                    id: sshMouse
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.sshPeer(modelData.ip, modelData.name)
                                }
                            }
                            Text {
                                textFormat: Text.PlainText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !peerRow.showCopied
                                       && (modelData.type === "P2P" || modelData.type === "Relayed")
                                text: modelData.type === "P2P" ? "P2P" : "relay"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: 10
                            }
                            Text {
                                textFormat: Text.PlainText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !peerRow.showCopied && modelData.latencyMs > 0
                                text: Math.round(modelData.latencyMs) + " ms"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: 10
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width; height: 1
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                }

                // --- footer actions ---
                Flow {
                    width: parent.width
                    spacing: 8
                    PopupButton {
                        label: root.connState === "connected" ? "Disconnect" : "Connect"
                        onActivated: { root.toggle(); root.close() }
                    }
                    PopupButton {
                        label: "Refresh"
                        onActivated: { root.flash(); root.refresh() }
                    }
                    PopupButton {
                        label: root.dashboardUrl !== "" ? "Dashboard" : "Status ▸"
                        onActivated: root.dashboardUrl !== "" ? root.openDashboard() : root.openStatusTerminal()
                    }
                    PopupButton {
                        label: (root.sessionExpiringSoon || root.sessionExpired) ? "Re-login" : ""
                        danger: true
                        onActivated: root.reLogin()
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Click a row (or your IP/name) to copy · hover a row for ssh"
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: 10
                }
            }
        }
    }
}
