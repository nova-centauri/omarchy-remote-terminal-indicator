#!/usr/bin/env python3
import importlib.util
import pathlib
import sys

path = pathlib.Path(__file__).resolve().parent / "ssh-identities.py"
spec = importlib.util.spec_from_file_location("ssh_identities", path)
mod = importlib.util.module_from_spec(spec)
sys.modules["ssh_identities"] = mod
spec.loader.exec_module(mod)

failed = 0


def eq(actual, expected, label):
    global failed
    if actual != expected:
        print("FAIL", label, "got", actual, "expected", expected)
        failed += 1
        return
    print("ok", label)


eq(mod.parse_ssh_argv(["ssh", "prod-db"]), "prod-db", "plain host")
eq(mod.parse_ssh_argv(["ssh", "user@prod-db"]), "prod-db", "user@host")
eq(mod.parse_ssh_argv(["ssh", "-p", "22", "prod-db"]), "prod-db", "-p 22")
eq(mod.parse_ssh_argv(["ssh", "-p22", "prod-db"]), "prod-db", "-p22")
eq(mod.parse_ssh_argv(["ssh", "-vv", "prod-db"]), "prod-db", "-vv")
eq(mod.parse_ssh_argv(["ssh", "-i", "key", "user@prod-db"]), "prod-db", "-i key")
eq(mod.parse_ssh_argv(["ssh", "-o", "StrictHostKeyChecking=no", "prod-db"]), "prod-db", "-o")
eq(mod.parse_ssh_argv(["ssh", "-J", "jump", "prod-db"]), "prod-db", "proxyjump")
eq(mod.parse_ssh_argv(["ssh", "prod-db", "ls"]), "prod-db", "remote command still a destination")
eq(mod.parse_ssh_argv(["ssh", "localhost"]), "", "skip localhost")
eq(mod.parse_ssh_argv(["ssh", "127.0.0.1"]), "", "skip loopback")
eq(mod.parse_ssh_argv(["ssh", "10.0.0.12"]), "10.0.0.12", "ipv4")
eq(mod.parse_ssh_argv(["ssh", "root@10.0.0.12"]), "10.0.0.12", "user@ipv4")
eq(mod.parse_ssh_argv(["ssh", "root@[2001:db8::1]"]), "2001:db8::1", "ipv6")
eq(mod.parse_ssh_argv(["ssh", "ssh://user@prod-db:22"]), "prod-db", "ssh url")
eq(mod.parse_ssh_argv(["ssh", "-O", "check", "prod-db"]), "", "control command skipped")
eq(mod.parse_ssh_argv(["ssh", "-G", "prod-db"]), "", "config dump skipped")
eq(mod.parse_ssh_argv(["ssh", "-W", "h:22", "prod-db"]), "", "stdio forward skipped")
eq(mod.parse_ssh_argv(["ssh", "--unknown", "prod-db"]), "", "unknown long opt")
eq(mod.parse_ssh_argv(["ssh", "-Z", "prod-db"]), "", "unknown short opt")
eq(mod.parse_ssh_argv(["ssh", "-n"]), "", "no destination")
eq(mod.parse_ssh_argv(["ssh", "prod-db;rm"]), "", "metachar host")
eq(mod.parse_ssh_argv(["ssh", "../etc/passwd"]), "", "path host")
eq(mod.parse_ssh_argv(["ssh", "a" * 300]), "", "overlong host")
eq(mod.parse_ssh_argv(["ssh", "-host"]), "", "option-like dest")
eq(mod.destination_from_token("prod-db:22"), "prod-db", "host:port")
eq(mod.valid_identity("bad host"), "", "space rejected")
eq(mod.valid_identity(""), "", "empty rejected")
eq(mod.parse_pid("0"), None, "pid 0")
eq(mod.parse_pid("1"), None, "pid 1")
eq(mod.parse_pid("12abc"), None, "pid junk")
eq(mod.parse_pid("4321") is not None, True, "pid ok")

if failed:
    sys.exit(1)
print("all ssh-identities tests passed")
