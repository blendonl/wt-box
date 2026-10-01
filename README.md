# wt-box

Per-worktree dev environments on Linux, isolated at the network layer.

`wt-box up`, run in a linked git worktree:
- gives that worktree its own LAN IP;
- symlinks the main worktree's `.env*` files in;
- registers `<repo>-<branch>.wt.test` with a local DNS;
- opens a tmux session inside the box.

Every worktree can then run the app on its normal port, and the hostname tells them apart:

```
http://<repo>-<branch>.wt.test:<app-port>
```

There are no containers and no images. A box is a network namespace with its own macvlan interface. Processes in it share the host's filesystem, packages and OS; only the network, and optionally the PID space, is isolated.

## What's here

| Script | What it does |
| --- | --- |
| `wt-box` | `up`, `down`, `list` and `url` for one worktree's box |
| `ensure-box` | Creates, enters and stops a box: a network namespace with a macvlan interface, an optional PID namespace, a tmux server inside it, and an optional browser container reachable over VNC. Runs as root. |
| `ensure-macvlan` | One-time setup: a rootful podman macvlan network, a host-side `mac-host` interface so the host can reach boxes, a systemd unit that recreates it on boot, and `/etc/podman/ensure-compose.conf` |
| `ensure-wt-dns` | One-time setup: dnsmasq serving names from `/etc/wt-boxes.d/`, plus a route-only `~wt.test` drop-in for systemd-resolved so only those names go to dnsmasq |
| `box-lite` | fzf project picker on the default tmux server. Enter opens a project on the host network; Ctrl-I opens it as an isolated `<project>@net` session whose panes each re-enter the box. |
| `switch-worktree-lite` | fzf worktree switcher with the same naming: `<project>`, `<project>-<branch>`, `<project>-<branch>@net` |
| `box-vnc-pw` | Prints the VNC password for box browser containers: `$BOX_VNC_PW`, or a random password generated on first use and kept in a `0600` file |

## Requirements

- Linux with systemd and systemd-resolved
- iproute2 with macvlan support
- rootful podman
- dnsmasq, tmux, zsh, fzf and git

The scripts were written and used on Arch.

## Setup

The scripts expect to live in `~/bin`.

```sh
install -m 755 bin/* ~/bin/
sudo ~/bin/ensure-macvlan     # one-time: macvlan network + host interface
sudo ~/bin/ensure-wt-dns      # one-time: dnsmasq + resolved routing for *.wt.test
```

`wt-box`, `box-lite` and `switch-worktree-lite` call `sudo -n ensure-box`, so your user needs to run that one script without a password. Create the rule with `sudo visudo -f /etc/sudoers.d/ensure-box`:

```
youruser ALL=(root) NOPASSWD: /home/youruser/bin/ensure-box
```

Read the security notes below before you add it.

## Usage

```sh
wt-box up               # from inside a linked worktree: create the box and attach
wt-box list             # all worktree boxes
wt-box url              # print this worktree's URL
wt-box down             # stop the box, release its IP, unregister its name
```

Notes:
- **`.env*` files.** They are symlinked from the main worktree, except `*.example`, `*.sample` and `*.dist`. A file that already exists in the worktree wins.
- **Name resolution.** Names resolve only on this host: dnsmasq listens on `127.0.0.1` and is reached through a systemd-resolved `~wt.test` drop-in, so other DNS, Tailscale's included, is untouched.
- **The main worktree.** Run there, `wt-box up` just opens a plain `box-lite` session, since there is nothing to isolate it from.

## Security notes

- **The sudoers rule gives passwordless root to whatever file sits at that path.** If your user can edit `~/bin/ensure-box`, the rule is as broad as `NOPASSWD: ALL`. The safer setup is a root-owned copy:
  1. Install it as `/usr/local/bin/ensure-box`, owner root, mode `755`.
  2. Point both the rule and the scripts' `ENSURE_BOX` variable at that copy.
- **A box isolates the network, not the user.** Code in a box runs as you, with your files. `--pid` gives it a private process table, but this is not a sandbox for untrusted code.
- **`/etc/wt-boxes.d` is owned by your user**, so `wt-box` can register names without sudo. Anything written there resolves locally under `.wt.test`.
- **The generated VNC password** is stored with mode `0600` in your home directory.

## Status

These scripts were extracted from my dotfiles and still assume the original machine:
- `ensure-box`, `box-lite`, `box-vnc-pw`, `ensure-wt-dns` and `ensure-macvlan` hard-code the user name `notpc` and its home directory.
- `box-lite` looks for projects under `/mnt/data/personal`, `/mnt/data/work` and `~/projects`.

Change these before running it as anyone else. Making the user and paths configurable is the next step.

## License

[MIT](LICENSE)
