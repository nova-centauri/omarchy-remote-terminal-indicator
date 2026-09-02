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

const local = ctx.buildLocalNames(["XER-OMARCHY", "xer-omarchy.local"])

eq(ctx.remoteHost("steve@XER-OMARCHY:~", local), null, "local host with :~")
eq(ctx.remoteHost("steve@XER-OMARCHY: ~", local), null, "local host with colon space")
eq(ctx.remoteHost("steve@localhost: /tmp", local), null, "localhost")
eq(ctx.remoteHost("root@wg-hub: ~", local), "wg-hub", "remote host")
eq(ctx.remoteHost("root@prod-db:/var/www", local), "prod-db", "remote path")
eq(ctx.remoteHost("root@10.0.0.12:~", local), "10.0.0.12", "ipv4")
eq(ctx.remoteHost("root@[2001:db8::1]: ~", local), "2001:db8::1", "ipv6")
eq(ctx.remoteHost("btop", local), null, "non ssh title")
eq(ctx.isTerminal({ lastIpcObject: { class: "foot", tags: ["terminal*"] } }), true, "foot terminal")
eq(ctx.isTerminal({ "class": "com.mitchellh.ghostty", tags: ["terminal*"], title: "root@wg-hub: ~" }), true, "hyprctl ghostty client")
eq(ctx.isTerminal({ lastIpcObject: { class: "firefox" } }), false, "firefox")
eq(ctx.colorFromIdentity("10.0.0.12").active.startsWith("rgb("), true, "active color")
eq(ctx.firstIpv4("10.0.0.12  STREAM  wg-hub"), "10.0.0.12", "getent parse")
eq(ctx.normalizeAddress("564d479934b0"), "0x564d479934b0", "address prefix")
eq(ctx.parseHyprGradient('{"gradient":"ff509475 0deg","set":true}'), "rgba(509475ff) 0deg", "theme active gradient")
eq(ctx.parseHyprGradient('{"gradient":"aa595959 0deg","set":true}'), "rgba(595959aa) 0deg", "theme inactive gradient")
eq(ctx.splitEventData("0xabc,root@wg-hub: ~")[1], "root@wg-hub: ~", "title event split")
eq(ctx.remoteHost("~", local), null, "cwd-only title")

if (process.exitCode)
  process.exit(process.exitCode)
console.log("all tests passed")
