#!/usr/bin/env python3
"""Map terminal PIDs to a destination taken from a local OpenSSH client.

Reads only argv PIDs and /proc. No shell, no DNS, no window titles.
A remote endpoint cannot enqueue work here; only a local ssh executable
in the terminal's process tree produces an identity.
"""

from __future__ import annotations

import json
import os
import re
import signal
import sys

MAX_PIDS = 64
MAX_NODES = 256
MAX_DEPTH = 8
MAX_CMDLINE = 4096
MAX_HOST = 253
MAX_PID = 4194304
ALARM_SECS = 1

SSH_OPT_TAKES_ARG = set("BbcDEeFIiJLlmOopQRSWw")
SSH_OPT_FLAGS = set("46AaCfGgKkMNnqsTtVvXxYy")
SKIP_OPT = set("OWQG")  # control/stdio/query/dump — not a login session we paint

IPV4_RE = re.compile(r"^(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$")
IPV6_RE = re.compile(r"^[0-9a-fA-F:]+$")
HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)
SSH_URL_RE = re.compile(
    r"^ssh://(?:[^@/?]+@)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(?::\d+)?(?:/.*)?$"
)


def fail_closed(_signum, _frame):
    sys.stdout.write("{}\n")
    sys.stdout.flush()
    os._exit(0)


def parse_pid(value: str) -> int | None:
    if not value or len(value) > 10 or not value.isdigit():
        return None
    pid = int(value)
    if pid < 2 or pid > MAX_PID:
        return None
    return pid


def read_link(path: str) -> str:
    try:
        return os.readlink(path)
    except OSError:
        return ""


def read_file(path: str, limit: int) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return b""
    try:
        return os.read(fd, limit)
    except OSError:
        return b""
    finally:
        os.close(fd)


def comm(pid: int) -> str:
    return read_file(f"/proc/{pid}/comm", 32).decode("utf-8", "replace").strip()


def is_ssh_exe(pid: int) -> bool:
    exe = read_link(f"/proc/{pid}/exe")
    if not exe:
        return False
    return os.path.basename(exe.split("\x00", 1)[0]) == "ssh"


def cmdline(pid: int) -> list[str]:
    raw = read_file(f"/proc/{pid}/cmdline", MAX_CMDLINE)
    if not raw:
        return []
    parts = raw.split(b"\0")
    out = []
    for part in parts:
        if not part:
            continue
        out.append(part.decode("utf-8", "replace"))
        if len(out) >= 64:
            break
    return out


def children_of(pid: int) -> list[int]:
    found: list[int] = []
    task_dir = f"/proc/{pid}/task"
    try:
        tids = os.listdir(task_dir)
    except OSError:
        return found
    for tid in tids[:16]:
        if not tid.isdigit():
            continue
        raw = read_file(f"{task_dir}/{tid}/children", 4096)
        if not raw:
            continue
        for token in raw.decode("ascii", "replace").split():
            child = parse_pid(token)
            if child is not None:
                found.append(child)
            if len(found) >= 64:
                return found
    return found


def unwrap_host(value: str) -> str:
    host = value.strip()
    if host.startswith("[") and "]" in host:
        return host[1 : host.index("]")].strip()
    return host


LOCAL_NAMES = {"localhost", "127.0.0.1", "::1"}


def valid_identity(host: str) -> str:
    value = host.strip()
    if not value or len(value) > MAX_HOST:
        return ""
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    if value.lower() in LOCAL_NAMES:
        return ""
    if IPV4_RE.match(value):
        return value
    if ":" in value and IPV6_RE.match(value) and len(value) <= 45:
        return value
    if HOSTNAME_RE.match(value):
        return value
    return ""


def destination_from_token(token: str) -> str:
    value = token.strip()
    if not value or len(value) > MAX_HOST + 32:
        return ""
    if value.startswith("-"):
        return ""
    match = SSH_URL_RE.match(value)
    if match:
        return valid_identity(unwrap_host(match.group(1)))
    if value.startswith("ssh://"):
        return ""
    if "@" in value:
        value = value.rsplit("@", 1)[1]
    value = unwrap_host(value)
    if value.count(":") == 1 and not value.startswith("["):
        host, port = value.split(":")
        if port.isdigit():
            value = host
    return valid_identity(value)


def parse_ssh_argv(argv: list[str]) -> str:
    if not argv:
        return ""
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg == "-" or not arg.startswith("-"):
            break
        if arg.startswith("--"):
            return ""
        opts = arg[1:]
        j = 0
        skip_rest = False
        while j < len(opts):
            opt = opts[j]
            if opt in SKIP_OPT:
                return ""
            if opt in SSH_OPT_TAKES_ARG:
                if j + 1 < len(opts):
                    skip_rest = True
                    break
                i += 1
                break
            if opt in SSH_OPT_FLAGS:
                j += 1
                continue
            return ""
        i += 1
        if skip_rest:
            continue
    if i >= len(argv):
        return ""
    return destination_from_token(argv[i])


def walk(root: int) -> str:
    queue = [(root, 0)]
    seen = set()
    nodes = 0
    while queue:
        pid, depth = queue.pop(0)
        if pid in seen or depth > MAX_DEPTH:
            continue
        seen.add(pid)
        nodes += 1
        if nodes > MAX_NODES:
            break
        if is_ssh_exe(pid) or comm(pid) == "ssh":
            if is_ssh_exe(pid):
                ident = parse_ssh_argv(cmdline(pid))
                if ident:
                    return ident
        if depth == MAX_DEPTH:
            continue
        for child in children_of(pid):
            if child not in seen:
                queue.append((child, depth + 1))
    return ""


def identities_for(pids: list[int]) -> dict[str, str]:
    out: dict[str, str] = {}
    for pid in pids[:MAX_PIDS]:
        ident = walk(pid)
        if ident:
            out[str(pid)] = ident
    return out


def main(argv: list[str]) -> int:
    signal.signal(signal.SIGALRM, fail_closed)
    signal.alarm(ALARM_SECS)
    pids = []
    seen = set()
    for token in argv[1:]:
        pid = parse_pid(token)
        if pid is None or pid in seen:
            continue
        seen.add(pid)
        pids.append(pid)
        if len(pids) >= MAX_PIDS:
            break
    sys.stdout.write(json.dumps(identities_for(pids), separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except Exception:
        sys.stdout.write("{}\n")
        raise SystemExit(0)
