const fs = require("fs")
const vm = require("vm")
const ctx = {}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(__dirname + "/HostBand.js", "utf8"), ctx)

function eq(actual, expected, label) {
  const left = JSON.stringify(actual)
  const right = JSON.stringify(expected)
  if (left !== right) {
    console.error("FAIL", label, "got", left, "expected", right)
    process.exitCode = 1
    return
  }
  console.log("ok", label)
}

eq(ctx.isTerminal({ lastIpcObject: { class: "foot", tags: ["terminal*"] } }), true, "foot terminal")
eq(ctx.isTerminal({ "class": "com.mitchellh.ghostty", tags: ["terminal*"], title: "root@wg-hub: ~" }), true, "hyprctl ghostty client")
eq(ctx.isTerminal({ lastIpcObject: { class: "firefox" } }), false, "firefox")
eq(ctx.colorFromIdentity("10.0.0.12").active.startsWith("rgb("), true, "active color")
eq(ctx.normalizeAddress("564d479934b0"), "0x564d479934b0", "address prefix")
eq(ctx.normalizeAddress("0xZZ"), "", "reject junk address")
eq(ctx.parseHyprGradient('{"gradient":"ff509475 0deg","set":true}'), "rgba(509475ff) 0deg", "theme active gradient")
eq(ctx.parseHyprGradient('{"gradient":"aa595959 0deg","set":true}'), "rgba(595959aa) 0deg", "theme inactive gradient")
eq(ctx.isValidIdentity("prod-db"), "prod-db", "hostname identity")
eq(ctx.isValidIdentity("10.0.0.12"), "10.0.0.12", "ipv4 identity")
eq(ctx.isValidIdentity("2001:db8::1"), "2001:db8::1", "ipv6 identity")
eq(ctx.isValidIdentity("prod-db;rm -rf /"), "", "reject shell host")
eq(ctx.isValidIdentity("a".repeat(300)), "", "reject overlong host")
eq(ctx.isValidIdentity("you@prod-db: ~"), "", "reject title text")
eq(ctx.isValidIdentity("localhost"), "", "reject localhost")
eq(ctx.isValidIdentity("127.0.0.1"), "", "reject loopback")
eq(ctx.isValidPid(1), false, "reject pid 1")
eq(ctx.isValidPid(4321), true, "accept pid")

const huge = "[" + "{},".repeat(ctx.LIMITS.maxClients + 2) + "{}]"
eq(ctx.parseClientsJson(huge).ok, true, "client cap still parses")
eq(ctx.parseClientsJson(huge).clients.length, ctx.LIMITS.maxClients, "client cap applied")
eq(ctx.parseClientsJson("x".repeat(ctx.LIMITS.maxClientsJsonBytes + 1)).ok, false, "json byte cap")
eq(ctx.parseClientsJson("not-json").ok, false, "json parse fail")

const terminals = ctx.takeTerminals([
  { address: "0xabc", class: "foot", pid: 100, title: "root@evil: ~" },
  { address: "0xdef", class: "firefox", pid: 101, title: "root@evil: ~" },
  { address: "nope", class: "foot", pid: 102 }
])
eq(terminals.length, 1, "only valid terminal kept")
eq(terminals[0].pid, 100, "terminal pid")
eq(ctx.parseIdentityMap('{"100":"prod-db","nope":"x"}').map["100"], "prod-db", "identity map")
eq(ctx.parseIdentityMap('{"100":"prod-db;rm"}').map["100"] === undefined, true, "reject bad identity")
eq(ctx.parseGetpropBatch("2\nff509475 0deg\naa595959 0deg\n").size, 2, "getprop batch size")
eq(ctx.parseGetpropBatch("2\nff509475 0deg\naa595959 0deg\n").active, "rgba(509475ff) 0deg", "getprop batch color")

const lua = ctx.buildPaintLua({
  "0xabc": { size: 3, active: "rgb(AABBCC)", inactive: "rgba(AABBCC99)" }
})
eq(lua.count, 1, "paint lua count")
eq(lua.lua.indexOf("0xabc") !== -1, true, "paint lua address")
eq(lua.lua.length <= ctx.LIMITS.maxLuaBytes, true, "paint lua bound")

const many = {}
for (let i = 0; i < 80; i++)
  many["0x" + i.toString(16)] = { size: 3, active: "rgb(AABBCC)", inactive: "rgba(AABBCC99)" }
eq(ctx.buildPaintLua(many).count <= ctx.LIMITS.maxPaintOps, true, "paint op cap")
eq(ctx.statusSessions(many).length, ctx.LIMITS.maxSessionsIpc, "ipc session cap")

if (process.exitCode)
  process.exit(process.exitCode)
console.log("all tests passed")
