# wt-box

Give every linked git worktree its own dev environment with its own LAN IP,
so several branches of the same app can run side by side on their usual
ports.

```
http://localhost:3000                   main worktree, host network
http://myapp-feat-login.wt.test:3000    linked worktree, same port
http://myapp-hotfix.wt.test:3000        another one, still no conflict
```

## The problem

With `git worktree` you can check out `main`, a feature branch and a hotfix
at the same time, but you cannot run them at the same time: every copy of
the app wants port 3000, its database wants 5432, and the compose services
publish the same host ports. The usual workarounds are editing ports per
branch or stopping one copy before starting another.

wt-box puts each linked worktree in a Linux network namespace with its own
macvlan interface, so it gets its own address on your LAN. Inside that
namespace nothing else is listening, so the app, its compose services and
its dev server all use their normal ports. A local DNS name
(`<repo>-<branch>.wt.test`) tells the copies apart.

Only the network is isolated. The worktree still uses your filesystem, your
installed tools and your user account, so there are no images to build and
nothing to sync.

## What's in here

| Script | Runs as | Purpose |
| --- | --- | --- |
| `wt-box` | you | Per-worktree front end: `up`, `down`, `list`, `url` |
| `ensure-box` | root (sudo) | Creates, enters, lists and stops network-namespace boxes |
| `box-lite` | you | tmux session manager and fzf project picker; `--exec-shell` runs as root |
| `switch-worktree-lite` | you | fzf picker for the worktrees of the current repo |
| `box-vnc-pw` | either | Prints (and on first use generates) the VNC password |
| `ensure-macvlan` | root, once | Host-side macvlan setup and `/etc/podman/ensure-compose.conf` |
| `ensure-wt-dns` | root, once | dnsmasq + systemd-resolved routing for `*.wt.test` |

## Requirements

- Linux with network namespace and macvlan support, IPv4 LAN, and a wired
  NIC (see [Limitations](#limitations))
- bash 4+, coreutils, util-linux (`unshare`, `nsenter`), iproute2 (`ip`),
  `getent`, `sudo`
- git, tmux, zsh (shells inside a box run `/usr/bin/zsh -l`)
- fzf, for the `box-lite` and `switch-worktree-lite` pickers
- podman: `ensure-macvlan` creates a podman network, and the browser
  container and the `docker` wrapper use it. `podman-compose` or
  `podman compose` is used for `docker compose` inside a box when present
- systemd and systemd-resolved (`resolvectl`)
- dnsmasq. `ensure-wt-dns` installs it with `pacman`, so as written it only
  runs on Arch Linux and derivatives
- A tmux config at `~/.config/tmux/tmux.conf` is used if it exists

## Install

```sh
git clone https://github.com/blendonl/wt-box.git
cd wt-box
./install.sh                          # symlinks bin/* into ~/.local/bin
```

`./install.sh DIR` links into another directory. `--copy` copies instead of
linking; use it to install root-owned copies, which is the safer option
because `ensure-box` runs as root (see [Security](#security)):

```sh
sudo ./install.sh --copy /usr/local/bin
```

The scripts find each other next to their own resolved path, so keep them
together in one directory.

### One-time setup

1. Host macvlan interface and config:

   ```sh
   sudo ensure-macvlan
   ```

   This detects your default-route interface, subnet and gateway, then

   - creates a rootful podman macvlan network `projects-macvlan` (wt-box
     itself does not use it),
   - creates `mac-host`, a macvlan interface on the host at `x.y.z.240`, so
     the host can reach the boxes,
   - installs `ensure-macvlan.service` to recreate `mac-host` at boot,
   - writes `/etc/podman/ensure-compose.conf`.

   Boxes get addresses from `x.y.z.200` to `x.y.z.239`, where `x.y.z` are
   the first three octets of the host's address. Make sure your router's
   DHCP server never hands those out. To use other addresses, pass
   overrides on the command line:

   ```sh
   sudo MACVLAN_POOL_START=192.168.1.100 MACVLAN_POOL_END=192.168.1.139 \
        MACVLAN_HOST_IP=192.168.1.140 MACVLAN_DNS=192.168.1.1 ensure-macvlan
   ```

   `MACVLAN_NETWORK_NAME` renames the podman network. `ENSURE_COMPOSE_CONFIG`
   changes where the config is written, but the other scripts only read
   `/etc/podman/ensure-compose.conf`, so leave it alone.

   At the end it prints steps for a `podman` group that can use the rootful
   podman socket. wt-box does not need them for `up`/`down`; see
   [podman and compose](#podman-and-compose-inside-a-box).

2. Local DNS for `*.wt.test`:

   ```sh
   sudo ensure-wt-dns
   ```

   Run it with `sudo` from the account that will use wt-box: that account
   gets ownership of `/etc/wt-boxes.d`, which `wt-box` rewrites without sudo.
   The script is idempotent and ends with a self-test.

3. Let your user run `ensure-box` without a password. `wt-box` and every
   pane of an isolated session call it with `sudo -n`. Read
   [Security](#security) first, then:

   ```sh
   sudo visudo -f /etc/sudoers.d/ensure-box
   ```

   ```
   youruser ALL=(root) NOPASSWD: /usr/local/bin/ensure-box
   ```

   Use the path `install.sh` printed: the real location of `ensure-box`
   (the clone's `bin/` for a symlink install, the target directory for
   `--copy`).

## Usage

### wt-box

Run from inside a linked worktree (`git worktree add ../myapp-login login`):

```
wt-box up [path]         create env for the worktree at path (default: cwd)
wt-box down [path|name]  stop env, release IP, unregister name
wt-box list              show all worktree boxes (alias: ls)
wt-box url [path]        print the URL for a worktree
```

`wt-box up`:

1. names the box `<repo>-<branch>`: both halves lowercased, runs of other
   characters turned into `-`, each cut to 40 characters. A detached HEAD
   becomes `detached-<short-sha>`;
2. symlinks the main worktree's `.env*` files into the worktree, skipping
   `*.example`, `*.sample` and `*.dist`. A file already in the worktree
   always wins;
3. runs `sudo -n ensure-box --no-tmux --no-enter --dir <worktree> <box>` to
   allocate an IP and create the namespace;
4. rewrites `/etc/wt-boxes.d/wt-boxes.hosts` from the live box state, so
   `<box>.wt.test` resolves to the box's IP;
5. creates the tmux session `<box>@net` on your default tmux server (through
   `box-lite --ensure <box> --isolate`), where every pane is a shell inside
   the box, and switches to it when you are already in tmux. Outside tmux,
   attach with `tmux attach -t '<box>@net'`;
6. prints the URL. The port is the first `PORT`, `APP_PORT`, `HTTP_PORT`
   or `SERVER_PORT` in the worktree's `.env`, or `<port>` if none is set.

Run in the main worktree, `wt-box up` only creates (or reuses) a plain
shared session named after the repo and prints its name; the main worktree
keeps using the host network.

`wt-box down` kills the `<box>` and `<box>@net` sessions, stops the box,
releases its IP and removes its DNS name.

### ensure-box

The engine behind wt-box. It can also be used on its own, with any box
name.

```
Usage: ensure-box [flags] <box_name>

Flags:
  --pid              Enable PID-namespace isolation (private /proc)
  --no-tmux          Skip tmux — drop into a plain shell (default: tmux)
  --no-enter         Create/ensure the box + tmux server but don't attach
  --dir PATH         Start shell in PATH (default: the worktree of the
                     current repo that has main or master checked out,
                     else your home)
  --browser          Launch a browser container in the box's network ns
  --browser-port N   VNC port for the browser (default: 6901)
  -c, --command CMD  Run CMD inside the box instead of an interactive shell

Subcommands:
  ensure-box list                 List all boxes
  ensure-box status <name>        Show box status
  ensure-box stop [--rm] <name>   Stop a box (--rm also releases IP)
```

`list` and `status` work without root, but only show the browser container
when run with `sudo` because it is a rootful container. Creating, entering
and stopping need `sudo`. `start`, `up` and `enter` are aliases for the
default action; `ls`, `st` and `down` for `list`, `status` and `stop`.

Without `-c` and `--no-tmux`, `ensure-box` starts a separate tmux server for
the box inside its namespace and attaches to it. See
[Known issues](#known-issues) before using that mode.

### box-lite

A project picker that keeps every project as a session on your default tmux
server. Bind it to a key, for example
`bind B display-popup -h 30 -w 100 -E box-lite`.

```
enter   shared session "<project>"      host network
ctrl-i  isolated session "<project>@net" own LAN IP via ensure-box
        (alt-i does the same; terminals send Ctrl-I as Tab, so Tab too)
ctrl-b  launch/report the box's browser container
ctrl-x  kill this project's sessions
ctrl-k  stop the box (netns + browser; IP stays reserved)
```

```
box-lite --list                                TSV of projects and state
box-lite --ensure <name> [--isolate] [--dir PATH]  create a session, print its name
box-lite --switch <session>                    attach or switch to it
```

The picker looks for git repos under the directories in `PROJECT_ROOTS` at
the top of `bin/box-lite`. `wt-box` does not depend on that list.

### switch-worktree-lite

Fuzzy-pick one of the current repo's worktrees and switch to its session:
`<project>` for the main worktree, `<project>-<branch>` for a linked one,
`<project>-<branch>@net` with `ctrl-i` (or `alt-i`/Tab) for the isolated
variant. It only creates and switches sessions; `wt-box up` also links the
`.env` files and registers the DNS name.

### box-vnc-pw

Prints the password for the browser containers. It uses `$BOX_VNC_PW` if
set, otherwise `$BOX_VNC_PW_FILE` or `~/.ensure-box/vnc-pw`, generating a
random 16-character password (mode 600) on first use. `sudo` drops
`BOX_VNC_PW`, so the containers that `ensure-box` starts use the file.

## How it works

### Network namespace and macvlan

For a new box, `ensure-box`:

1. creates the namespace (`ip netns add <box>`) and brings up `lo`;
2. adds a macvlan interface `mv-<last octet>` in bridge mode on the
   physical NIC from the config, gives it a stable, locally administered
   MAC derived from the IP (`02:00:` plus the four octets in hex), and
   moves it into the namespace;
3. assigns the IP with the subnet's prefix length and a default route via
   the LAN gateway;
4. writes `/etc/netns/<box>/resolv.conf` (the configured DNS server) and
   `/etc/netns/<box>/hosts` (the host's entries plus `127.0.0.1 <box>`),
   which `ip netns exec` bind-mounts over `/etc` inside the box;
5. adds a `/32` route to the box via `mac-host`, because a macvlan parent
   cannot talk to its own children directly;
6. writes a `docker` wrapper to `/tmp/ensure-box/<box>/bin` and puts it
   first on `PATH` inside the box.

In wt-box and box-lite sessions, shells inside a box run as you, in a
private UTS namespace whose hostname is the box name, and see the box's own
`/etc/resolv.conf`, which points at `MACVLAN_DNS` from the config.

### IP allocation

Addresses come from `MACVLAN_IP_POOL_START`..`MACVLAN_IP_POOL_END` in
`/etc/podman/ensure-compose.conf`. Only the last octet varies, so the pool
lives inside one /24. The first free address is recorded as
`<box> <ip>` in `/tmp/compose/ip-allocations.txt`, and a box keeps it
until `ensure-box stop --rm` (which `wt-box down` uses). `ensure-box stop`
without `--rm` keeps the address reserved.

### Local DNS

`ensure-wt-dns` configures dnsmasq on `127.0.0.1` with
`hostsdir=/etc/wt-boxes.d`, which dnsmasq re-reads whenever it changes, and
adds a systemd-resolved drop-in with `DNS=127.0.0.1` and `Domains=~wt.test`.
resolved sends only `*.wt.test` lookups there. `wt-box` rebuilds
`wt-boxes.hosts` from `/tmp/ensure-box/*/state` on every `up` and `down`,
so stale names disappear on their own. Every box with a LAN IP gets a name,
including the ones box-lite created. The names resolve on this host only,
not from other machines on the LAN.

### tmux

wt-box and box-lite keep everything on your default tmux server. An
isolated session's `default-command` is

```
sudo -n ensure-box --dir "$(pwd)" -c "box-lite --exec-shell '$TMUX' '$TMUX_PANE'" <box>
```

so every new pane or window re-enters the box: `ensure-box` recreates the
namespace if it is missing, enters it with `ip netns exec` plus
`unshare --uts`, and `box-lite --exec-shell` drops back to your user with
the tmux variables restored. If that fails the pane prints
`[box-lite] netns entry failed — host shell` and gives you a normal host
shell.

Used on its own, `ensure-box` instead runs one tmux server per box on
`/tmp/tmux-ensure-box/<box>/tmux.sock`, started inside the namespace as
your user.

### Browser container

`ensure-box --browser <box>` (or `ctrl-b` in box-lite) runs
`kasmweb/brave:1.16.0` as `<box>-browser` with rootful podman inside the
box's namespace. It is a full browser whose `localhost` is the box. Open
`https://<box-ip>:6901` and log in as `kasm_user` with the password from
`box-vnc-pw`. `ensure-box stop` removes the container.

### podman and compose inside a box

The wrapper turns `docker run` and `docker create` into
`podman --network ns:/var/run/netns/<box> ...`, and `docker compose` into
`podman-compose --podman-args '--network ns:...'` or
`podman --network ns:... compose`. Any other `docker` command goes to
`/usr/bin/docker` unchanged. Joining a namespace that root created usually
requires rootful podman, which is what the `podman` group steps printed by
`ensure-macvlan` set up.

`wt-box up` also sets `COMPOSE_PROJECT_NAME=<box>` in the session's tmux
environment (see [Known issues](#known-issues)).

### Files

| Path | Written by | Contents |
| --- | --- | --- |
| `/etc/podman/ensure-compose.conf` | ensure-macvlan | NIC, subnet, gateway, DNS, IP pool |
| `/etc/systemd/system/ensure-macvlan.service` | ensure-macvlan | recreates `mac-host` at boot |
| `/etc/dnsmasq.d/wt-boxes.conf`, `conf-dir` line in `/etc/dnsmasq.conf` | ensure-wt-dns | local dnsmasq |
| `/etc/systemd/resolved.conf.d/wt-boxes.conf` | ensure-wt-dns | `~wt.test` routing |
| `/etc/wt-boxes.d/wt-boxes.hosts` | wt-box | `<ip> <box>.wt.test` lines |
| `/etc/netns/<box>/` | ensure-box | per-box `resolv.conf` and `hosts` |
| `/tmp/compose/ip-allocations.txt` | ensure-box | IP leases |
| `/tmp/ensure-box/<box>/` | ensure-box | box state and the `docker` wrapper |
| `/tmp/tmux-ensure-box/<box>/` | ensure-box | per-box tmux socket (standalone mode) |
| `/tmp/wt-box/<box>` | wt-box | worktree, main worktree and branch |
| `~/.ensure-box/vnc-pw` | box-vnc-pw | VNC password |

## Security

Read this before adding the sudoers rule.

- **A NOPASSWD rule for `ensure-box` amounts to passwordless root for that
  user.** `-c CMD` runs any command as root, and box names and `--dir` are
  placed into shell commands and `rm -rf` paths without validation. Only
  grant it to your own account on a machine you control, and never pass
  untrusted box names.
- **Keep the scripts root-owned.** If `ensure-box` (or `box-lite`, which it
  runs as root) sits in a directory your user can write, such as a clone in
  your home, anything running as you can change it and then run it as root
  without a password. Install with `sudo ./install.sh --copy /usr/local/bin`
  and point the rule at `/usr/local/bin/ensure-box`.
- **State lives in `/tmp` and is read by root.** `ensure-box` creates
  `/tmp/ensure-box` and `/tmp/compose` as root and `source`s the state
  files in them. On a machine with other local users, one of them could
  create those paths first after a reboot. Use wt-box on single-user
  machines.
- **Boxes are on your LAN.** Anything listening on `0.0.0.0` inside a box is
  reachable from the local network at the box's IP, including the browser
  container on port 6901. Your host firewall does not cover them: netfilter
  rules are per network namespace and a new namespace starts with none.
- `/etc/wt-boxes.d` belongs to your user, so any process running as you can
  publish names through the local dnsmasq.
- `ensure-box` and `box-lite` print the VNC password to the terminal.
- `ensure-macvlan` and `ensure-wt-dns` change system configuration: the
  files in the table above, a podman network, the `mac-host` interface,
  and the dnsmasq and systemd-resolved services.

## Limitations

- Linux only, with systemd and systemd-resolved. `ensure-wt-dns` uses
  `pacman`, so on other distributions install dnsmasq yourself and apply
  its two drop-ins by hand.
- macvlan needs a wired NIC in practice. Most Wi-Fi drivers and access
  points drop frames from extra MAC addresses. Switches with port security
  may limit the number of MACs per port.
- IPv4 only. The pool is a range of last octets inside one /24 and must
  stay clear of your DHCP range.
- The dnsmasq drop-in forwards to `100.100.100.100` (Tailscale MagicDNS).
  Change `server=` in `/etc/dnsmasq.d/wt-boxes.conf` if you do not use
  Tailscale.
- Box state lives in `/tmp` and in network namespaces, so a reboot removes
  all boxes and IP leases. `mac-host` comes back through the systemd unit;
  run `wt-box up` again. Old `*.wt.test` names stay in the hosts file until
  the next `wt-box up` or `down`.
- Shells inside a box are always `/usr/bin/zsh -l`.
- Only the network (and, with `--pid`, the process list) is isolated.
  Files, installed tools and your user account are shared with the host.
- Without `/etc/podman/ensure-compose.conf`, `ensure-box` falls back to host
  mode with no network isolation; `wt-box` and isolated box-lite sessions
  refuse to run.
- In macvlan mode `--browser-port` only changes the address that gets
  printed; the browser always listens on 6901.

## Known issues

- In its standalone tmux and plain-shell modes (`ip netns exec` does not
  create a UTS namespace) and in host mode, `ensure-box` runs
  `hostname <box>` in the host's UTS namespace, which renames the host.
  wt-box and box-lite are not affected: they use `-c` in macvlan mode,
  which adds `unshare --uts`.
- `COMPOSE_PROJECT_NAME`, set by `wt-box up`, does not reach the shells in
  isolated panes: `sudo` resets the environment and `box-lite --exec-shell`
  forwards only the tmux, terminal and D-Bus variables.
- `ensure-macvlan.service` has `2>/dev/null || true` in `ExecStop`.
  systemd does not use a shell, so those words reach `ip` as arguments and
  stopping the unit fails. `ip link del mac-host` removes the interface.

## Undo

```sh
sudo systemctl disable --now ensure-macvlan.service
sudo rm /etc/systemd/system/ensure-macvlan.service /etc/podman/ensure-compose.conf
sudo ip link del mac-host
sudo podman network rm projects-macvlan

sudo rm /etc/dnsmasq.d/wt-boxes.conf /etc/systemd/resolved.conf.d/wt-boxes.conf
sudo rm -r /etc/wt-boxes.d
sudo systemctl disable --now dnsmasq
sudo systemctl restart systemd-resolved

sudo rm /etc/sudoers.d/ensure-box
```

`ensure-wt-dns` also appends `conf-dir=/etc/dnsmasq.d/,*.conf` to
`/etc/dnsmasq.conf`; remove it if you had no other use for it.
