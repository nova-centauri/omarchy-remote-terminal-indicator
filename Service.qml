import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "HostBand.js" as HostBand

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.nova-centauri.remote-terminal-indicator"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cacheDir: home + "/.cache/omarchy-remote-terminal-indicator"
  readonly property string legacyCacheDir: home + "/.cache/omarchy-ssh-host-band"
  readonly property string hostsPath: cacheDir + "/hosts"
  readonly property var pluginEntry: root.entryFromConfig()
  readonly property int cornerSize: Math.max(16, Math.min(48, Math.round(HostBand.numberFrom(root.pluginEntry.cornerSize, 26))))

  property var localNames: ({})
  property var hostIps: ({})
  property var banded: ({})
  property var pendingResolves: ({})
  property var resolveQueue: []
  property bool hostsLoaded: false
  property bool restoredBorders: false
  property string lastError: ""
  property int bandedCount: 0
  property int lastClientCount: 0

  ListModel {
    id: markerModel
  }

  function entryFromConfig() {
    var plugins = root.shell && root.shell.shellConfig ? root.shell.shellConfig.plugins : null
    if (!Array.isArray(plugins)) return ({})
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i] && String(plugins[i].id) === root.pluginId)
        return plugins[i]
    }
    return ({})
  }

  function luaEscape(value) {
    return String(value == null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  }

  function themeBorderSize() {
    try {
      var raw = JSON.parse(borderSizeProc.lastText || "")
      var n = Number(raw && raw["int"])
      if (isFinite(n) && n >= 0) return n
    } catch (e) {}
    return 2
  }

  function themeActiveBorder() {
    return HostBand.parseHyprGradient(activeBorderProc.lastText) || "rgba(509475ff)"
  }

  function themeInactiveBorder() {
    return HostBand.parseHyprGradient(inactiveBorderProc.lastText) || "rgba(595959aa)"
  }

  function refreshTheme() {
    if (!borderSizeProc.running) borderSizeProc.running = true
    if (!activeBorderProc.running) activeBorderProc.running = true
    if (!inactiveBorderProc.running) inactiveBorderProc.running = true
  }

  function restoreTerminalBorders() {
    if (restoreProc.running) return
    var lua = [
      "local function set(w, p, v) hl.dispatch(hl.dsp.window.set_prop({ window = w, prop = p, value = v })) end",
      "local size = " + Number(root.themeBorderSize()),
      "local active = \"" + luaEscape(root.themeActiveBorder()) + "\"",
      "local inactive = \"" + luaEscape(root.themeInactiveBorder()) + "\"",
      "for _, w in ipairs(hl.get_windows() or {}) do",
      "  local class = string.lower(tostring(w.class or \"\"))",
      "  if class:find(\"ghostty\", 1, true) or class:find(\"foot\", 1, true) or class:find(\"kitty\", 1, true) or class:find(\"alacritty\", 1, true) or class:find(\"wezterm\", 1, true) then",
      "    set(w, \"border_size\", size)",
      "    set(w, \"active_border_color\", active)",
      "    set(w, \"inactive_border_color\", inactive)",
      "  end",
      "end"
    ].join("\n")
    restoreProc.command = ["hyprctl", "eval", lua]
    restoreProc.running = true
    root.restoredBorders = true
  }

  function rememberHost(name, ip) {
    if (!name || !ip) return
    if (root.hostIps[name] === ip && root.hostIps[name.toLowerCase()] === ip)
      return
    var next = {}
    for (var key in root.hostIps) next[key] = root.hostIps[key]
    next[name] = ip
    next[name.toLowerCase()] = ip
    root.hostIps = next
    hostsFile.setText(HostBand.serializeHostsFile(next))
  }

  function cachedIp(host) {
    if (!host) return ""
    return root.hostIps[host] || root.hostIps[host.toLowerCase()] || ""
  }

  function enqueueResolve(host) {
    if (!host || HostBand.isIpv4(host) || HostBand.isIpv6(host)) return
    if (root.cachedIp(host) || root.pendingResolves[host]) return
    var pending = {}
    for (var key in root.pendingResolves) pending[key] = root.pendingResolves[key]
    pending[host] = true
    root.pendingResolves = pending
    root.resolveQueue = root.resolveQueue.concat([host])
    root.runNextResolve()
  }

  function runNextResolve() {
    if (resolveProc.running) return
    if (root.resolveQueue.length === 0) return
    var host = root.resolveQueue[0]
    root.resolveQueue = root.resolveQueue.slice(1)
    resolveProc.command = ["getent", "ahostsv4", host]
    resolveProc.host = host
    resolveProc.running = true
  }

  function finishResolve(host, text, exitCode) {
    var ip = HostBand.firstIpv4(text)
    var pending = {}
    for (var key in root.pendingResolves) {
      if (key !== host) pending[key] = root.pendingResolves[key]
    }
    root.pendingResolves = pending
    if (exitCode === 0 && ip)
      root.rememberHost(host, ip)
    root.scan()
    root.runNextResolve()
  }

  function sessionIdentity(win) {
    if (!HostBand.isTerminal(win)) return ""
    var host = HostBand.remoteHost(win.title || "", root.localNames)
    if (!host) return ""
    if (HostBand.isIpv4(host) || HostBand.isIpv6(host)) {
      root.rememberHost(host, host)
      return host
    }
    var ip = root.cachedIp(host)
    if (ip) return ip
    root.enqueueResolve(host)
    return host
  }

  function applyClients(raw) {
    var clients
    try {
      clients = JSON.parse(raw || "[]")
    } catch (e) {
      root.lastError = String(e)
      return
    }
    if (!Array.isArray(clients)) {
      root.lastError = "hyprctl clients: not an array"
      return
    }
    if (!root.restoredBorders)
      root.restoreTerminalBorders()

    root.lastClientCount = clients.length
    var nextBanded = {}
    markerModel.clear()
    for (var i = 0; i < clients.length; i++) {
      var client = clients[i]
      var address = HostBand.normalizeAddress(client && client.address)
      if (!address) continue
      var identity = ""
      try {
        identity = root.sessionIdentity(client)
      } catch (e) {
        root.lastError = String(e)
        continue
      }
      if (!identity) continue
      nextBanded[address] = identity
      if (!HostBand.clientVisible(client)) continue
      var rect = HostBand.clientRect(client)
      if (!isFinite(rect.x) || !isFinite(rect.y) || rect.w < 24 || rect.h < 24)
        continue
      var palette = HostBand.cornerPalette(identity)
      markerModel.append({
        address: address,
        winX: rect.x,
        winY: rect.y,
        winW: rect.w,
        winH: rect.h,
        fill: palette.fill,
        dim: palette.dim,
        sheen: palette.sheen
      })
    }
    root.banded = nextBanded
    root.bandedCount = Object.keys(nextBanded).length
  }

  function scan() {
    if (clientsProc.running) return
    clientsProc.running = true
  }

  function scanSoon() {
    root.refreshTheme()
    scanTimer.restart()
  }

  function adoptLocalName(name) {
    var names = []
    for (var key in root.localNames) names.push(key)
    names.push(name)
    root.localNames = HostBand.buildLocalNames(names)
  }

  function screenNumber(screen, name, fallback) {
    var value = screen && screen[name] !== undefined ? Number(screen[name]) : Number(fallback)
    return isFinite(value) ? value : Number(fallback || 0)
  }

  function markerOnScreen(screen, winX, winY, winW, winH) {
    if (!screen || winW <= 0 || winH <= 0) return false
    var sx = root.screenNumber(screen, "virtualX", 0)
    var sy = root.screenNumber(screen, "virtualY", 0)
    var sw = root.screenNumber(screen, "width", 0)
    var sh = root.screenNumber(screen, "height", 0)
    if (sw <= 0 || sh <= 0) return false
    var mx = winX + winW - root.cornerSize
    var my = winY
    return mx < sx + sw && mx + root.cornerSize > sx && my < sy + sh && my + root.cornerSize > sy
  }

  function statusJson() {
    var sessions = []
    for (var address in root.banded) {
      sessions.push({ address: address, identity: root.banded[address] })
    }
    return JSON.stringify({
      pluginId: root.pluginId,
      cornerSize: root.cornerSize,
      bandedCount: root.bandedCount,
      lastClientCount: root.lastClientCount,
      sessions: sessions,
      lastError: root.lastError
    })
  }

  Timer {
    id: scanTimer
    interval: 40
    repeat: false
    onTriggered: root.scan()
  }

  Timer {
    interval: 400
    running: true
    repeat: true
    onTriggered: root.scan()
  }

  FileView {
    id: hostsFile
    path: root.hostsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.hostIps = HostBand.parseHostsFile(text())
      root.hostsLoaded = true
      root.scanSoon()
    }
    onLoadFailed: {
      root.hostsLoaded = true
      root.scanSoon()
    }
  }

  Process {
    id: mkdirProc
    command: ["bash", "-c",
      "mkdir -p \"$1\" && if [ ! -f \"$1/hosts\" ] && [ -f \"$2/hosts\" ]; then cp -n \"$2/hosts\" \"$1/hosts\"; fi",
      "migrate-cache", root.cacheDir, root.legacyCacheDir]
    onExited: hostsFile.reload()
  }

  Process {
    id: shortHostnameProc
    command: ["hostname", "-s"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptLocalName(text)
    }
  }

  Process {
    id: fullHostnameProc
    command: ["hostname", "-f"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptLocalName(text)
    }
  }

  Process {
    id: borderSizeProc
    property string lastText: ""
    command: ["hyprctl", "getoption", "general:border_size", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: borderSizeProc.lastText = text
    }
  }

  Process {
    id: activeBorderProc
    property string lastText: ""
    command: ["hyprctl", "getoption", "general:col.active_border", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: activeBorderProc.lastText = text
    }
  }

  Process {
    id: inactiveBorderProc
    property string lastText: ""
    command: ["hyprctl", "getoption", "general:col.inactive_border", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: inactiveBorderProc.lastText = text
    }
  }

  Process {
    id: restoreProc
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClients(text)
    }
  }

  Process {
    id: resolveProc
    property string host: ""
    property string lastOut: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: resolveProc.lastOut = text
    }
    onExited: function(exitCode) {
      root.finishResolve(resolveProc.host, resolveProc.lastOut, exitCode)
    }
  }

  Connections {
    target: Hyprland
    ignoreUnknownSignals: true
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "windowtitle"
          || name === "windowtitlev2"
          || name === "openwindow"
          || name === "closewindow"
          || name === "movewindow"
          || name === "movewindowv2"
          || name === "activewindow"
          || name === "activewindowv2"
          || name === "fullscreen"
          || name === "changefloatingmode"
          || name === "workspace"
          || name === "workspacev2")
        root.scanSoon()
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: markerModel.count > 0
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-remote-terminal-indicator"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      readonly property int screenX: root.screenNumber(modelData, "virtualX", 0)
      readonly property int screenY: root.screenNumber(modelData, "virtualY", 0)

      Repeater {
        model: markerModel

        CornerMark {
          required property int winX
          required property int winY
          required property int winW
          required property int winH
          required property string fill
          required property string dim
          required property string sheen

          visible: root.markerOnScreen(panel.modelData, winX, winY, winW, winH)
          markSize: root.cornerSize
          x: winX + winW - width - panel.screenX
          y: winY - panel.screenY
          fillColor: fill
          dimColor: dim
          sheenColor: sheen
        }
      }
    }
  }

  IpcHandler {
    target: root.pluginId
    function status(): string { return root.statusJson() }
    function refresh(): string {
      root.scan()
      return "ok"
    }
  }

  Component.onCompleted: {
    root.localNames = HostBand.buildLocalNames([])
    mkdirProc.running = true
    shortHostnameProc.running = true
    fullHostnameProc.running = true
    root.refreshTheme()
    root.scanSoon()
  }
}
