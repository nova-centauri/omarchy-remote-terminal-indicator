# SSH Host Band

A colored box around any Omarchy terminal that is SSHed into a remote host.

The color is stable per machine: it is derived from the destination IP when
that is known, so `prod-db` is always the same band, on every window, after
every reconnect.

This is the Omarchy shell plugin form of the Hyprland `ssh-host-band` window
hook. It watches terminal titles (`user@host: cwd`), thickens the Hyprland
border, and paints it with that host's color. When the SSH session ends, the
window goes back to the theme border.

Works with Foot, Ghostty, Kitty, Alacritty, WezTerm, and anything Hyprland
tags as a terminal.

## Install

```sh
omarchy plugin add https://github.com/nova-centauri/omarchy-ssh-host-band.git --enable
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
omarchy-shell io.github.nova-centauri.ssh-host-band status
omarchy-shell io.github.nova-centauri.ssh-host-band refresh
```

## Configure

Optional keys on the `plugins[]` entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.nova-centauri.ssh-host-band",
  "borderSize": 5
}
```

`borderSize` is the Hyprland border width while a session is remote. Default
is `5`. Theme border width is restored when you disconnect.

Host → IP mappings are cached in `~/.cache/omarchy-ssh-host-band/hosts` so a
given hostname keeps the same color even if DNS is slow next time.

## Remove

```sh
omarchy plugin remove io.github.nova-centauri.ssh-host-band
```

Open SSH windows drop back to the theme border as the plugin unloads.

## License

MIT. See [LICENSE](LICENSE).
