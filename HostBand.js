var LIMITS = {
  maxClientsJsonBytes: 524288,
  maxClients: 256,
  maxTerminals: 64,
  maxBanded: 32,
  maxPids: 64,
  maxPaintOps: 32,
  maxLuaBytes: 12288,
  maxSessionsIpc: 32,
  maxHostBytes: 253,
  maxGetpropBytes: 4096,
  maxIdentityJsonBytes: 16384,
  clientsTimeoutMs: 1500,
  identityTimeoutMs: 1500,
  captureTimeoutMs: 1500,
  paintTimeoutMs: 2000,
  pollIdleMs: 2500,
  pollActiveMs: 1000,
  pollFailMaxMs: 8000,
  scanDebounceMs: 250
}

function trim(value) {
  return String(value == null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function clipString(value, max) {
  var text = String(value == null ? "" : value)
  var limit = Number(max)
  if (!isFinite(limit) || limit < 0) return ""
  if (text.length <= limit) return text
  return text.slice(0, limit)
}

function objectCount(map) {
  var n = 0
  var source = map || {}
  for (var key in source) n++
  return n
}

function copyObject(map) {
  var next = {}
  var source = map || {}
  for (var key in source) next[key] = source[key]
  return next
}

function luaEscape(value) {
  return String(value == null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function normalizeAddress(value) {
  var address = trim(value)
  if (!address) return ""
  if (address.length > 32) return ""
  if (address.indexOf("0x") === 0 || address.indexOf("0X") === 0) {
    if (!/^0x[0-9a-fA-F]{1,16}$/.test(address)) return ""
    return address.toLowerCase()
  }
  if (/^[0-9a-fA-F]{1,16}$/.test(address))
    return "0x" + address.toLowerCase()
  return ""
}

function isValidPid(value) {
  var n = Number(value)
  return isFinite(n) && Math.floor(n) === n && n >= 2 && n <= 4194304
}

function isIpv4(value) {
  var host = trim(value)
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) return false
  var parts = host.split(".")
  for (var i = 0; i < parts.length; i++) {
    var n = Number(parts[i])
    if (n > 255) return false
  }
  return true
}

function isIpv6(value) {
  var host = trim(value)
  if (host.indexOf(":") === -1 || host.indexOf(" ") !== -1) return false
  if (host.length > 45) return false
  return /^[0-9a-fA-F:]+$/.test(host)
}

function isValidHostname(value) {
  var host = trim(value)
  if (!host || host.length > LIMITS.maxHostBytes) return false
  if (host.charAt(0) === "-" || host.charAt(host.length - 1) === "-") return false
  if (host.indexOf("..") !== -1) return false
  return /^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/.test(host)
}

function isValidIdentity(value) {
  var host = trim(value)
  if (!host || host.length > LIMITS.maxHostBytes) return ""
  var lowered = host.toLowerCase()
  if (lowered === "localhost" || lowered === "127.0.0.1" || lowered === "::1")
    return ""
  if (isIpv4(host) || isIpv6(host) || isValidHostname(host)) return host
  return ""
}

function windowClass(win) {
  if (!win) return ""
  if (win["class"] || win.initialClass)
    return String(win["class"] || win.initialClass || "")
  var ipc = win.lastIpcObject || {}
  return String(ipc["class"] || ipc.initialClass || "")
}

function windowTags(win) {
  if (!win) return []
  var tags = win.tags
  if (tags == null && win.lastIpcObject)
    tags = win.lastIpcObject.tags
  if (Array.isArray(tags)) return tags
  if (typeof tags === "string") return [tags]
  return []
}

function windowPid(win) {
  if (!win) return 0
  if (win.pid != null) return Number(win.pid)
  var ipc = win.lastIpcObject || {}
  return Number(ipc.pid || 0)
}

function isTerminal(win) {
  var klass = windowClass(win).toLowerCase()
  if (klass.indexOf("ghostty") !== -1
      || klass.indexOf("foot") !== -1
      || klass.indexOf("kitty") !== -1
      || klass.indexOf("alacritty") !== -1
      || klass.indexOf("wezterm") !== -1
      || klass.indexOf("org.omarchy.") !== -1
      || klass.indexOf("tui.") !== -1)
    return true
  var tags = windowTags(win)
  for (var i = 0; i < tags.length; i++) {
    if (String(tags[i]).toLowerCase().indexOf("terminal") !== -1)
      return true
  }
  return false
}

function parseClientsJson(raw) {
  var text = String(raw == null ? "" : raw)
  if (text.length > LIMITS.maxClientsJsonBytes) {
    return { ok: false, error: "hyprctl clients: output too large", clients: [] }
  }
  var clients
  try {
    clients = JSON.parse(text || "[]")
  } catch (e) {
    return { ok: false, error: String(e), clients: [] }
  }
  if (!Array.isArray(clients))
    return { ok: false, error: "hyprctl clients: not an array", clients: [] }
  if (clients.length > LIMITS.maxClients)
    clients = clients.slice(0, LIMITS.maxClients)
  return { ok: true, error: "", clients: clients }
}

function takeTerminals(clients) {
  var out = []
  var list = clients || []
  for (var i = 0; i < list.length; i++) {
    var client = list[i]
    if (!isTerminal(client)) continue
    var address = normalizeAddress(client && client.address)
    var pid = windowPid(client)
    if (!address || !isValidPid(pid)) continue
    out.push({
      address: address,
      pid: pid,
      client: client
    })
    if (out.length >= LIMITS.maxTerminals) break
  }
  return out
}

function parseIdentityMap(raw) {
  var text = String(raw == null ? "" : raw)
  if (text.length > LIMITS.maxIdentityJsonBytes)
    return { ok: false, error: "ssh-identities: output too large", map: {} }
  var parsed
  try {
    parsed = JSON.parse(text || "{}")
  } catch (e) {
    return { ok: false, error: "ssh-identities: " + String(e), map: {} }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return { ok: false, error: "ssh-identities: not an object", map: {} }
  var map = {}
  var count = 0
  for (var key in parsed) {
    if (!isValidPid(key)) continue
    var identity = isValidIdentity(parsed[key])
    if (!identity) continue
    map[String(Number(key))] = identity
    count++
    if (count >= LIMITS.maxPids) break
  }
  return { ok: true, error: "", map: map }
}

function parseGetpropBatch(text) {
  var body = clipString(text, LIMITS.maxGetpropBytes)
  var lines = body.split("\n")
  var values = []
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i])
    if (!line) continue
    if (line.charAt(0) === "{") {
      try {
        var obj = JSON.parse(line)
        if (obj && obj.border_size != null) values.push(String(obj.border_size))
        else if (obj && obj.active_border_color != null) values.push(String(obj.active_border_color))
        else if (obj && obj.inactive_border_color != null) values.push(String(obj.inactive_border_color))
      } catch (e) {}
      continue
    }
    values.push(line)
  }
  if (values.length < 3) return null
  var size = Number(values[0])
  if (!isFinite(size) || size < 0 || size > 20) return null
  var active = parseHyprGradient(values[1])
  var inactive = parseHyprGradient(values[2])
  if (!active || !inactive) return null
  return {
    size: Math.round(size),
    active: active,
    inactive: inactive
  }
}

function hue2rgb(p, q, t) {
  var value = t
  if (value < 0) value += 1
  if (value > 1) value -= 1
  if (value < 1 / 6) return p + (q - p) * 6 * value
  if (value < 1 / 2) return q
  if (value < 2 / 3) return p + (q - p) * (2 / 3 - value) * 6
  return p
}

function hslToRgb(h, s, l) {
  var hue = ((h % 360) + 360) % 360 / 360
  var r, g, b
  if (s === 0) {
    r = g = b = l
  } else {
    var q = l < 0.5 ? l * (1 + s) : (l + s - l * s)
    var p = 2 * l - q
    r = hue2rgb(p, q, hue + 1 / 3)
    g = hue2rgb(p, q, hue)
    b = hue2rgb(p, q, hue - 1 / 3)
  }
  return [
    Math.round(r * 255),
    Math.round(g * 255),
    Math.round(b * 255)
  ]
}

function fnv1a(text) {
  var hash = 2166136261
  var value = String(text || "")
  for (var i = 0; i < value.length; i++) {
    hash = ((hash ^ value.charCodeAt(i)) * 16777619) % 4294967296
  }
  return hash
}

function hueFromIdentity(identity) {
  var parts = String(identity || "").match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)
  if (parts) {
    return (Number(parts[1]) * 73
      + Number(parts[2]) * 179
      + Number(parts[3]) * 283
      + Number(parts[4]) * 419) % 360
  }
  return ((fnv1a(identity) % 360) + 360) % 360
}

function hex2(n) {
  var value = Math.max(0, Math.min(255, n)).toString(16).toUpperCase()
  return value.length === 1 ? "0" + value : value
}

function colorFromIdentity(identity) {
  var hue = hueFromIdentity(identity)
  var active = hslToRgb(hue, 0.72, 0.56)
  var inactive = hslToRgb(hue, 0.62, 0.38)
  return {
    hue: hue,
    active: "rgb(" + hex2(active[0]) + hex2(active[1]) + hex2(active[2]) + ")",
    inactive: "rgba(" + hex2(inactive[0]) + hex2(inactive[1]) + hex2(inactive[2]) + "99)"
  }
}

function numberFrom(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function parseHyprGradient(raw) {
  var text = trim(raw)
  if (!text) return ""
  try {
    var obj = JSON.parse(text)
    if (obj && obj.gradient) text = String(obj.gradient)
    else if (obj && obj.str) text = String(obj.str)
  } catch (e) {}
  var parts = trim(text).split(/\s+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var tok = parts[i]
    if (/^[0-9a-fA-F]{8}$/.test(tok))
      out.push("rgba(" + tok.slice(2) + tok.slice(0, 2) + ")")
    else if (/^[0-9a-fA-F]{6}$/.test(tok))
      out.push("rgb(" + tok + ")")
    else if (/^-?\d+(?:deg)?$/.test(tok) || tok === "deg")
      out.push(tok)
    else if (/^rgba?\(/i.test(tok))
      out.push(tok)
    else
      return ""
  }
  return out.join(" ")
}

function setLine(addr, spec) {
  var lines = [
    "  if addr == \"" + luaEscape(addr) + "\" then"
  ]
  lines.push("    set(w, \"border_size\", " + Number(spec.size) + ")")
  lines.push("    set(w, \"active_border_color\", \"" + luaEscape(spec.active) + "\")")
  lines.push("    set(w, \"inactive_border_color\", \"" + luaEscape(spec.inactive) + "\")")
  lines.push("  end")
  return lines
}

function buildPaintLua(ops) {
  var lines = [
    "local function set(w, p, v) hl.dispatch(hl.dsp.window.set_prop({ window = w, prop = p, value = v })) end",
    "for _, w in ipairs(hl.get_windows() or {}) do",
    "  local addr = tostring(w.address or \"\")"
  ]
  var count = 0
  var used = {}
  var source = ops || {}
  for (var addr in source) {
    var spec = source[addr]
    var normalized = normalizeAddress(addr)
    if (!spec || !normalized || used[normalized]) continue
    if (spec.size == null || !spec.active || !spec.inactive) continue
    used[normalized] = true
    var chunk = setLine(normalized, spec)
    var candidate = lines.concat(chunk)
    candidate.push("end")
    if (candidate.join("\n").length > LIMITS.maxLuaBytes) break
    lines = lines.concat(chunk)
    count++
    if (count >= LIMITS.maxPaintOps) break
  }
  lines.push("end")
  return {
    lua: lines.join("\n"),
    count: count
  }
}

function statusSessions(banded) {
  var sessions = []
  var source = banded || {}
  for (var address in source) {
    var row = source[address]
    var identity = row && row.identity ? row.identity : row
    sessions.push({
      address: address,
      identity: String(identity || "")
    })
    if (sessions.length >= LIMITS.maxSessionsIpc) break
  }
  return sessions
}
