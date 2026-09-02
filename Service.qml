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
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir).replace(/\/$/, "") : ""
  readonly property string identityScript: root.sourceDir + "/ssh-identities.py"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cacheDir: home + "/.cache/omarchy-remote-terminal-indicator"
  readonly property var pluginEntry: root.entryFromConfig()
  readonly property int borderSize: Math.max(1, Math.min(8, Math.round(HostBand.numberFrom(root.pluginEntry.borderSize, 3))))

  property var terminals: []
  property var identities: ({})
  property var banded: ({})
  property var priors: ({})
  property var pendingOps: ({})
  property var inFlightOps: ({})
  property var captureQueue: []
  property bool paintQueued: false
  property bool identityQueued: false
  property bool restoreSent: false
  property string lastError: ""
  property int bandedCount: 0
  property int lastClientCount: 0
  property int failStreak: 0
  property int paintFailures: 0

  function entryFromConfig() {
    var plugins = root.shell && root.shell.shellConfig ? root.shell.shellConfig.plugins : null
    if (!Array.isArray(plugins)) return ({})
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i] && String(plugins[i].id) === root.pluginId)
        return plugins[i]
    }
    return ({})
  }

  function recordFailure(message) {
    root.lastError = String(message || "unknown error")
    root.failStreak = Math.min(4, root.failStreak + 1)
    var next = HostBand.LIMITS.pollIdleMs * Math.pow(2, root.failStreak)
    pollTimer.interval = Math.min(HostBand.LIMITS.pollFailMaxMs, next)
  }

  function recordSuccess() {
    root.failStreak = 0
    pollTimer.interval = root.bandedCount > 0 ? HostBand.LIMITS.pollActiveMs : HostBand.LIMITS.pollIdleMs
  }

  function queueOp(address, spec) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr || !spec) return
    if (HostBand.objectCount(root.pendingOps) >= HostBand.LIMITS.maxPaintOps && !root.pendingOps[addr])
      return
    var next = HostBand.copyObject(root.pendingOps)
    next[addr] = spec
    root.pendingOps = next
  }

  function captureBatch(address) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr) return []
    var selector = "address:" + addr
    return [
      "getprop " + selector + " border_size",
      "getprop " + selector + " active_border_color",
      "getprop " + selector + " inactive_border_color"
    ]
  }

  function runNextCapture() {
    if (captureProc.running) return
    if (root.captureQueue.length === 0) {
      root.flushPaint()
      return
    }
    var address = root.captureQueue[0]
    root.captureQueue = root.captureQueue.slice(1)
    if (root.priors[address]) {
      root.runNextCapture()
      return
    }
    captureProc.address = address
    captureProc.command = ["hyprctl", "--batch", root.captureBatch(address).join(" ; ")]
    captureProc.running = true
  }

  function enqueueCapture(address) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr || root.priors[addr]) return
    for (var i = 0; i < root.captureQueue.length; i++) {
      if (root.captureQueue[i] === addr) return
    }
    if (root.captureQueue.length >= HostBand.LIMITS.maxBanded) return
    root.captureQueue = root.captureQueue.concat([addr])
    root.runNextCapture()
  }

  function rememberPrior(address, prior) {
    var addr = HostBand.normalizeAddress(address)
    if (!addr || !prior) return
    var next = HostBand.copyObject(root.priors)
    next[addr] = prior
    root.priors = next
  }

  function restoreSpec(address) {
    var prior = root.priors[address]
    if (prior && prior.size != null && prior.active && prior.inactive)
      return { size: prior.size, active: prior.active, inactive: prior.inactive }
    return null
  }

  function paintSpec(identity) {
    var colors = HostBand.colorFromIdentity(identity)
    return {
      size: root.borderSize,
      active: colors.active,
      inactive: colors.inactive
    }
  }

  function flushPaint() {
    var ops = root.pendingOps
    if (HostBand.objectCount(ops) === 0) return
    if (paintProc.running) {
      root.paintQueued = true
      return
    }
    var built = HostBand.buildPaintLua(ops)
    if (!built.count || !built.lua) {
      root.recordFailure("paint script empty or too large")
      return
    }
    root.pendingOps = ({})
    root.inFlightOps = ops
    paintFile.setText(built.lua)
    paintProc.command = ["hyprctl", "eval", built.lua]
    paintProc.running = true
  }

  function markApplied(ok) {
    var ops = root.inFlightOps || {}
    var next = HostBand.copyObject(root.banded)
    for (var addr in ops) {
      if (!next[addr]) continue
      if (ok) next[addr].applied = true
      else next[addr].applied = false
    }
    root.banded = next
    root.inFlightOps = ({})
    if (!ok) {
      root.paintFailures += 1
      root.recordFailure("hyprctl eval failed")
    }
  }

  function applyIdentities(map) {
    var nextBanded = {}
    var count = 0
    var terminals = root.terminals || []
    for (var i = 0; i < terminals.length; i++) {
      var row = terminals[i]
      var identity = map[String(row.pid)] || ""
      if (!identity) {
        var restore = root.restoreSpec(row.address)
        if (restore && root.banded[row.address])
          root.queueOp(row.address, restore)
        continue
      }
      if (count >= HostBand.LIMITS.maxBanded) break
      var current = root.banded[row.address]
      nextBanded[row.address] = {
        identity: identity,
        pid: row.pid,
        applied: current && current.identity === identity && current.applied === true
      }
      count++
      if (!root.priors[row.address]) {
        root.enqueueCapture(row.address)
        continue
      }
      if (!nextBanded[row.address].applied)
        root.queueOp(row.address, root.paintSpec(identity))
    }
    for (var oldAddr in root.banded) {
      if (nextBanded[oldAddr]) continue
      var prior = root.restoreSpec(oldAddr)
      if (prior) root.queueOp(oldAddr, prior)
    }
    root.banded = nextBanded
    root.bandedCount = count
    if (root.captureQueue.length === 0)
      root.flushPaint()
  }

  function runIdentities() {
    if (identityProc.running) {
      root.identityQueued = true
      return
    }
    if (!root.sourceDir || root.sourceDir.indexOf("..") !== -1) {
      root.recordFailure("plugin sourceDir missing")
      return
    }
    var pids = []
    var seen = {}
    var terminals = root.terminals || []
    for (var i = 0; i < terminals.length; i++) {
      var pid = terminals[i].pid
      if (!HostBand.isValidPid(pid) || seen[pid]) continue
      seen[pid] = true
      pids.push(String(pid))
      if (pids.length >= HostBand.LIMITS.maxPids) break
    }
    if (pids.length === 0) {
      root.applyIdentities({})
      return
    }
    identityProc.command = ["python3", root.identityScript].concat(pids)
    identityProc.running = true
  }

  function applyClients(raw) {
    var parsed = HostBand.parseClientsJson(raw)
    if (!parsed.ok) {
      root.recordFailure(parsed.error)
      return
    }
    root.lastError = ""
    root.lastClientCount = parsed.clients.length
    root.terminals = HostBand.takeTerminals(parsed.clients)
    root.recordSuccess()
    root.runIdentities()
  }

  function scan() {
    if (clientsProc.running) return
    clientsProc.running = true
  }

  function scanSoon() {
    scanTimer.restart()
  }

  function restoreLua() {
    var ops = {}
    var count = 0
    for (var address in root.banded) {
      var spec = root.restoreSpec(address)
      if (!spec) continue
      ops[address] = spec
      count++
      if (count >= HostBand.LIMITS.maxPaintOps) break
    }
    for (var pending in root.pendingOps) {
      if (ops[pending]) continue
      var queued = root.pendingOps[pending]
      if (queued && queued.size != null) ops[pending] = queued
    }
    return HostBand.buildPaintLua(ops)
  }

  function restoreDetached() {
    if (root.restoreSent) return
    var built = root.restoreLua()
    if (!built.count || !built.lua) return
    root.restoreSent = true
    paintFile.setText(built.lua)
    var argv = ["systemd-run", "--user", "--collect", "--quiet", "--no-block", "--", "hyprctl", "eval", built.lua]
    if (typeof Quickshell.execDetached === "function")
      Quickshell.execDetached(argv)
    else {
      paintProc.command = argv
      paintProc.running = true
    }
  }

  function statusJson() {
    return JSON.stringify({
      pluginId: root.pluginId,
      identitySource: "local-ssh-process",
      borderSize: root.borderSize,
      bandedCount: root.bandedCount,
      lastClientCount: root.lastClientCount,
      sessions: HostBand.statusSessions(root.banded),
      paintFailures: root.paintFailures,
      lastError: root.lastError
    })
  }

  Timer {
    id: scanTimer
    interval: HostBand.LIMITS.scanDebounceMs
    repeat: false
    onTriggered: root.scan()
  }

  Timer {
    id: pollTimer
    interval: HostBand.LIMITS.pollIdleMs
    running: true
    repeat: true
    onTriggered: root.scan()
  }

  Timer {
    id: clientsTimeout
    interval: HostBand.LIMITS.clientsTimeoutMs
    running: clientsProc.running
    onTriggered: {
      clientsProc.running = false
      root.recordFailure("hyprctl clients timed out")
    }
  }

  Timer {
    id: identityTimeout
    interval: HostBand.LIMITS.identityTimeoutMs
    running: identityProc.running
    onTriggered: {
      identityProc.running = false
      root.recordFailure("ssh-identities timed out")
      root.applyIdentities({})
    }
  }

  Timer {
    id: captureTimeout
    interval: HostBand.LIMITS.captureTimeoutMs
    running: captureProc.running
    onTriggered: {
      captureProc.running = false
      root.recordFailure("hyprctl getprop timed out")
      root.runNextCapture()
    }
  }

  Timer {
    id: paintTimeout
    interval: HostBand.LIMITS.paintTimeoutMs
    running: paintProc.running
    onTriggered: {
      paintProc.running = false
      root.markApplied(false)
    }
  }

  FileView {
    id: paintFile
    path: root.cacheDir + "/last-paint.lua"
    printErrors: false
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.cacheDir]
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClients(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.recordFailure("hyprctl clients exited " + exitCode)
    }
  }

  Process {
    id: identityProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = HostBand.parseIdentityMap(text)
        if (!parsed.ok) {
          root.recordFailure(parsed.error)
          root.applyIdentities({})
          return
        }
        root.identities = parsed.map
        root.applyIdentities(parsed.map)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.lastError === "")
        root.recordFailure("ssh-identities exited " + exitCode)
      if (root.identityQueued) {
        root.identityQueued = false
        root.runIdentities()
      }
    }
  }

  Process {
    id: captureProc
    property string address: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var prior = HostBand.parseGetpropBatch(text)
        if (prior)
          root.rememberPrior(captureProc.address, prior)
        else
          root.recordFailure("hyprctl getprop: unusable output")
      }
    }
    onExited: function(exitCode) {
      var addr = captureProc.address
      var identity = ""
      if (root.banded[addr] && root.banded[addr].identity)
        identity = root.banded[addr].identity
      if (exitCode === 0 && identity && root.priors[addr])
        root.queueOp(addr, root.paintSpec(identity))
      root.runNextCapture()
    }
  }

  Process {
    id: paintProc
    onExited: function(exitCode) {
      root.markApplied(exitCode === 0)
      if (root.paintQueued) {
        root.paintQueued = false
        root.flushPaint()
      }
    }
  }

  Connections {
    target: Hyprland
    ignoreUnknownSignals: true
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "openwindow"
          || name === "closewindow"
          || name === "activewindow"
          || name === "activewindowv2"
          || name === "changefloatingmode"
          || name === "windowtitle"
          || name === "windowtitlev2")
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
    mkdirProc.running = true
    root.scanSoon()
  }

  Component.onDestruction: root.restoreDetached()
}
