function trim(value) {
  return String(value == null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function lower(value) {
  return trim(value).toLowerCase()
}

function normalizeAddress(value) {
  var address = trim(value)
  if (!address) return ""
  if (address.indexOf("0x") === 0 || address.indexOf("0X") === 0)
    return address.toLowerCase()
  if (/^[0-9a-fA-F]+$/.test(address))
    return "0x" + address.toLowerCase()
  return address
}

function isIpv4(value) {
  return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(trim(value))
}

function isIpv6(value) {
  var host = trim(value)
  return host.indexOf(":") !== -1 && host.indexOf(" ") === -1
}

function parseHostsFile(body) {
  var map = {}
  var lines = String(body || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = trim(lines[i]).match(/^(\S+)\s+(\S+)$/)
    if (!match) continue
    map[match[1]] = match[2]
    map[match[1].toLowerCase()] = match[2]
  }
  return map
}

function serializeHostsFile(map) {
  var seen = {}
  var lines = []
  var source = map || {}
  for (var name in source) {
    var ip = source[name]
    if (!name || !ip || seen[name]) continue
    seen[name] = true
    lines.push(name + " " + ip)
  }
  lines.sort()
  return lines.length ? lines.join("\n") + "\n" : ""
}

function buildLocalNames(names) {
  var map = {
    localhost: true,
    "127.0.0.1": true,
    "::1": true
  }
  var list = names || []
  for (var i = 0; i < list.length; i++) {
    var value = trim(list[i])
    if (!value) continue
    map[value] = true
    map[value.toLowerCase()] = true
    var short = value.split(".")[0]
    if (short) {
      map[short] = true
      map[short.toLowerCase()] = true
    }
  }
  return map
}

function isLocalHost(host, localNames) {
  var value = trim(host)
  if (!value) return true
  if (value === "localhost" || value === "127.0.0.1" || value === "::1")
    return true
  if (localNames && (localNames[value] || localNames[value.toLowerCase()]))
    return true
  return false
}

function extractHost(rest) {
  var value = trim(rest)
  if (!value) return ""
  var bracket = value.match(/^\[([^\]]+)\](?::.*)?$/)
  if (bracket) return trim(bracket[1])
  var withPath = value.match(/^(.+?)(?::(?:~|\/|\s).*)$/)
  if (withPath) return trim(withPath[1])
  return value
}

function remoteHost(title, localNames) {
  var value = trim(title).replace(/\s+/g, " ")
  if (!value) return null
  var match = value.match(/^([^@\s]+)@(.+)$/)
  if (!match) return null
  var host = extractHost(match[2])
  if (!host || isLocalHost(host, localNames)) return null
  return host
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
  return fnv1a(identity) % 360
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

function firstIpv4(text) {
  var match = String(text || "").match(/\b(\d{1,3}(?:\.\d{1,3}){3})\b/)
  return match ? match[1] : ""
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
    else
      out.push(tok)
  }
  return out.join(" ")
}

function splitEventData(data) {
  var text = String(data == null ? "" : data)
  var comma = text.indexOf(",")
  if (comma === -1) return [trim(text), ""]
  return [trim(text.slice(0, comma)), text.slice(comma + 1)]
}
