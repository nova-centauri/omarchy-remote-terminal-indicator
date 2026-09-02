# Remote Terminal Indicator

Colors the Hyprland border of an Omarchy terminal while a **local OpenSSH
client** is running in that window's process tree. The color is hashed from
the destination argument of that `ssh` process (`ssh prod-db` and
`ssh 10.0.0.12` are different identities). When the local `ssh` process
exits, the plugin restores the border properties it captured on that window
before it painted.

This is a decorative indicator. It does **not** read window titles, so a
remote host cannot impersonate another machine by sending OSC title
sequences, and it cannot enqueue DNS or resolver work. Title text is never
used as evidence that an SSH session exists.

Works with Foot, Ghostty, Kitty, Alacritty, WezTerm, and anything Hyprland
tags as a terminal. SSH inside tmux or screen is not detected: those
clients live under the multiplexer, not the terminal process.

## Install

```sh
omarchy plugin add https://github.com/nova-centauri/omarchy-remote-terminal-indicator.git --enable
```

The shell picks it up without a restart. To force a rescan:

```sh
omarchy-shell shell rescanPlugins
```

## Use

SSH as you already do from the terminal:

```sh
ssh you@prod-db
ssh root@10.0.0.12
```

Inspect live sessions:

```sh
omarchy-shell io.github.nova-centauri.remote-terminal-indicator status
omarchy-shell io.github.nova-centauri.remote-terminal-indicator refresh
```

## Configure

Optional keys on the `plugins[]` entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.nova-centauri.remote-terminal-indicator",
  "borderSize": 3
}
```

`borderSize` is the Hyprland border width while a local `ssh` process is
present. Default is `3`. The captured per-window border is restored when
that process ends or the plugin is removed.

## Remove

```sh
omarchy plugin remove io.github.nova-centauri.remote-terminal-indicator
```

Open SSH windows drop back to their captured border via a detached
`systemd-run` restore so unload does not cancel the cleanup.

## License

MIT. See [LICENSE](LICENSE).
