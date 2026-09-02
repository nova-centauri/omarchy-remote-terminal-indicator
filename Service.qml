import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
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
  readonly property int borderSize: Math.max(1, Math.min(8, Math.round(HostBand.numberFrom(root.pluginEntry.borderSize, 3))))

  property var localNames: ({})
  property var hostIps: ({})
  property var banded: ({})
  property var pendingOps: ({})
  property var pendingResolves: ({})
  property var resolveQueue: []
  property bool hostsLoaded: false
  property bool paintQueued: false
  property string lastError: ""
  property int bandedCount: 0
  property int lastClientCount: 0

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

  function queueOp(address, spec) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr) return
    var next = {}
    for (var key in root.pendingOps) next[key] = root.pendingOps[key]
    next[addr] = spec
    root.pendingOps = next
  }

  function buildPaintLua(ops) {
    var lines = [
      "local theme_size = " + Number(root.themeBorderSize()),
      "local theme_active = \"" + luaEscape(root.themeActiveBorder()) + "\"",
      "local theme_inactive = \"" + luaEscape(root.themeInactiveBorder()) + "\"",
      "local function set(w, p, v) hl.dispatch(hl.dsp.window.set_prop({ window = w, prop = p, value = v })) end",
      "for _, w in ipairs(hl.get_windows() or {}) do",
      "  local addr = tostring(w.address or \"\")"
    ]
    for (var addr in ops) {
      var spec = ops[addr]
      if (!spec) continue
      if (spec.restore) {
        lines.push("  if addr == \"" + luaEscape(addr) + "\" then")
        lines.push("    set(w, \"border_size\", theme_size)")
        lines.push("    set(w, \"active_border_color\", theme_active)")
        lines.push("    set(w, \"inactive_border_color\", theme_inactive)")
        lines.push("  end")
      } else {
        lines.push("  if addr == \"" + luaEscape(addr) + "\" then")
        lines.push("    set(w, \"border_size\", " + Number(spec.size) + ")")
        lines.push("    set(w, \"active_border_color\", \"" + luaEscape(spec.active) + "\")")
        lines.push("    set(w, \"inactive_border_color\", \"" + luaEscape(spec.inactive) + "\")")
        lines.push("  end")
      }
    }
    lines.push("end")
    return lines.join("\n")
  }

  function flushPaint() {
    var ops = root.pendingOps
    var empty = true
    for (var k in ops) { empty = false; break }
    if (empty) return
    if (paintProc.running) {
      root.paintQueued = true
      return
    }
    root.pendingOps = ({})
    var lua = root.buildPaintLua(ops)
    paintFile.setText(lua)
    paintProc.command = ["hyprctl", "eval", lua]
    paintProc.running = true
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

    root.lastClientCount = clients.length
    var seen = {}
    var nextBanded = {}
    for (var i = 0; i < clients.length; i++) {
      var client = clients[i]
      var address = HostBand.normalizeAddress(client && client.address)
      if (!address) continue
      seen[address] = true
      var identity = ""
      try {
        identity = root.sessionIdentity(client)
      } catch (e) {
        root.lastError = String(e)
        continue
      }
      if (!identity) {
        if (root.banded[address])
          root.queueOp(address, { restore: true })
        continue
      }
      nextBanded[address] = identity
      var colors = HostBand.colorFromIdentity(identity)
      root.queueOp(address, {
        size: root.borderSize,
        active: colors.active,
        inactive: colors.inactive
      })
    }
    for (var oldAddr in root.banded) {
      if (!seen[oldAddr])
        root.queueOp(oldAddr, { restore: true })
    }
    root.banded = nextBanded
    root.bandedCount = Object.keys(nextBanded).length
    root.flushPaint()
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

  function restoreAll() {
    for (var address in root.banded)
      root.queueOp(address, { restore: true })
    root.flushPaint()
  }

  function statusJson() {
    var sessions = []
    for (var address in root.banded) {
      sessions.push({ address: address, identity: root.banded[address] })
    }
    return JSON.stringify({
      pluginId: root.pluginId,
      borderSize: root.borderSize,
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
    interval: 500
    running: true
    repeat: true
    onTriggered: root.scan()
  }

  FileView {
    id: paintFile
    path: root.cacheDir + "/last-paint.lua"
    printErrors: false
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
    id: paintProc
    onExited: function() {
      if (root.paintQueued) {
        root.paintQueued = false
        root.flushPaint()
      }
    }
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
          || name === "activewindow"
          || name === "activewindowv2")
        root.scanSoon()
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

  Component.onDestruction: root.restoreAll()
}
