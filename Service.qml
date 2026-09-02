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

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.nova-centauri.ssh-host-band"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cacheDir: home + "/.cache/omarchy-ssh-host-band"
  readonly property string hostsPath: cacheDir + "/hosts"
  readonly property var pluginEntry: root.entryFromConfig()
  readonly property int borderSize: Math.max(1, Math.min(20, Math.round(HostBand.numberFrom(root.pluginEntry.borderSize, 5))))

  property var localNames: ({})
  property var hostIps: ({})
  property var banded: ({})
  property var pendingResolves: ({})
  property var resolveQueue: []
  property bool hostsLoaded: false
  property string lastError: ""
  property int bandedCount: 0

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

  function setProp(address, prop, value) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr) return
    Hyprland.dispatch(
      'hl.dsp.window.set_prop({ window = "'
        + luaEscape(addr)
        + '", prop = "'
        + luaEscape(prop)
        + '", value = "'
        + luaEscape(value)
        + '" })'
    )
  }

  function themeBorderSize() {
    try {
      var raw = JSON.parse(borderSizeProc.lastText || "")
      var n = Number(raw && raw["int"])
      if (isFinite(n) && n >= 0) return n
    } catch (e) {}
    return 2
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

  function applyBand(address, identity) {
    var colors = HostBand.colorFromIdentity(identity)
    root.setProp(address, "active_border_color", colors.active)
    root.setProp(address, "inactive_border_color", colors.inactive)
    root.setProp(address, "border_size", String(root.borderSize))
    var next = {}
    for (var key in root.banded) next[key] = root.banded[key]
    next[address] = identity
    root.banded = next
    root.bandedCount = Object.keys(next).length
  }

  function restore(address) {
    if (!address) return
    root.setProp(address, "border_size", String(root.themeBorderSize()))
    root.setProp(address, "active_border_color", "unset")
    root.setProp(address, "inactive_border_color", "unset")
    if (!root.banded[address]) return
    var next = {}
    for (var key in root.banded) {
      if (key !== address) next[key] = root.banded[key]
    }
    root.banded = next
    root.bandedCount = Object.keys(next).length
  }

  function restoreAll() {
    var addresses = []
    for (var address in root.banded) addresses.push(address)
    for (var i = 0; i < addresses.length; i++)
      root.restore(addresses[i])
  }

  function consider(toplevel) {
    if (!toplevel) return
    var address = HostBand.normalizeAddress(toplevel.address)
    if (!address) return
    if (!HostBand.isTerminal(toplevel)) {
      if (root.banded[address]) root.restore(address)
      return
    }

    var host = HostBand.remoteHost(toplevel.title, root.localNames)
    if (!host) {
      if (root.banded[address]) root.restore(address)
      return
    }

    var identity = host
    if (HostBand.isIpv4(host) || HostBand.isIpv6(host)) {
      identity = host
      root.rememberHost(host, host)
    } else {
      var ip = root.cachedIp(host)
      if (ip) identity = ip
      else root.enqueueResolve(host)
    }

    if (root.banded[address] === identity) return
    root.applyBand(address, identity)
  }

  function scan() {
    var seen = {}
    try {
      var values = Hyprland.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var toplevel = values[i]
        var address = HostBand.normalizeAddress(toplevel && toplevel.address)
        if (address) seen[address] = true
        root.consider(toplevel)
      }
    } catch (e) {
      root.lastError = String(e)
    }
    for (var bandedAddress in root.banded) {
      if (!seen[bandedAddress]) {
        var next = {}
        for (var key in root.banded) {
          if (key !== bandedAddress) next[key] = root.banded[key]
        }
        root.banded = next
      }
    }
    root.bandedCount = Object.keys(root.banded).length
  }

  function scanSoon() {
    scanTimer.restart()
  }

  function adoptLocalName(name) {
    var names = []
    for (var key in root.localNames) names.push(key)
    names.push(name)
    root.localNames = HostBand.buildLocalNames(names)
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
    command: ["mkdir", "-p", root.cacheDir]
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
      if (name === "openwindow"
          || name === "closewindow"
          || name === "windowtitle"
          || name === "windowtitlev2"
          || name === "activewindow"
          || name === "activewindowv2")
        root.scanSoon()
    }
  }

  Connections {
    target: Hyprland.toplevels
    ignoreUnknownSignals: true
    function onValuesChanged() { root.scanSoon() }
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
    borderSizeProc.running = true
    root.scanSoon()
  }

  Component.onDestruction: root.restoreAll()
}
