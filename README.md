# Remote Terminal Indicator

Colors the Hyprland border of any Omarchy terminal that has a remote SSH
session open. The color is derived from the destination IP, so a given
machine always gets the same band — on every window, after every reconnect.

It watches terminal titles (`user@host: cwd`) and paints a thin host-colored
frame. When the remote session ends, the theme border comes back.

Works with Foot, Ghostty, Kitty, Alacritty, WezTerm, and anything Hyprland
tags as a terminal.

## Install

```sh
omarchy plugin add https://github.com/nova-centauri/omarchy-remote-terminal-indicator.git --enable
```

The shell picks it up without a restart. To force a rescan:

```sh
omarchy-shell shell rescanPlugins
```

## Use

SSH as you already do. The terminal title has to look like a remote shell:

```
you@prod-db: ~
you@staging:/var/www
root@10.0.0.12:~
```

Foot, Ghostty, and the usual prompt-title setups already emit that. Local
titles (`you@your-laptop: ~`) are ignored.

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

`borderSize` is the Hyprland border width while a session is remote. Default
is `3`. Theme border width is restored when you disconnect.

Host → IP mappings are cached in
`~/.cache/omarchy-remote-terminal-indicator/hosts` so a given hostname keeps
the same color even if DNS is slow next time.

## Remove

```sh
omarchy plugin remove io.github.nova-centauri.remote-terminal-indicator
```

Open SSH windows drop back to the theme border as the plugin unloads.

## License

MIT. See [LICENSE](LICENSE).
