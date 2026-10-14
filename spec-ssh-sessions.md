# Persistent sessions on remote hosts (ssh)

Status: draft for the design group. Milestone M10 of the persistent-sessions
plan.

Revision 2 (2026-10-12): adds the shared ssh connection (5.1), the ssh
options (5.2), a bootstrap that works with all login shells (6.1, 6.2), the
remote runtime directory (7.6), process lifetime on the remote host (7.7),
link flow control (7.4), the Linux port (10), and questions Q10–Q20. Q2 is
resolved.

## 1. Summary

A persistent pane can run its shell on another computer. The session helper,
`tecolot-sessiond`, runs on the remote host and owns the shell there. The app
connects to it through `ssh`. When the network drops, or when the Mac sleeps
or the app quits, the shell continues to run on the remote host. The app
connects again and shows the same screen and scrollback.

The pane looks and works like a local persistent pane. It uses the same
protocol, the same renderer and the same row cache. Only the transport is
different: an ssh channel instead of a Unix socket.

The app makes one authenticated ssh connection per host and shares it. The
probe, the install and the bridge are separate commands on that connection.
They do not log in again.

## 2. Decisions already made

- The app uploads the matching helper to the remote host when the helper is
  missing or has another version. The user does not install anything.
- Closing a pane or a window detaches. The session ends only when its shell
  exits or when the user selects Terminate Session.
- The helper protocol is private. Both ends come from the same Tecolot
  release, or the app is newer (an app update must work with helpers that
  still run on remote hosts).
- The app uses the system `ssh` (`/usr/bin/ssh`). Tecolot does not contain an
  SSH implementation.

## 3. Goals and non-goals

Goals:

1. Open a persistent tab or window on a remote host from a profile or from a
   "New Remote Session" command.
2. Keep the session through network drops, Wi-Fi changes, sleep, app quit and
   app crash.
3. Attach to remote sessions from the session list. Show the sessions of each
   host in its own section.
4. Stay responsive on slow links: typing, scrolling and Ctrl-C during a flood.
5. Use the user's ssh setup: `~/.ssh/config`, keys, the agent, ProxyJump,
   hardware keys.
6. One login for each connection to a host. All steps of the connection and
   all panes on the host share it.

Non-goals (for this milestone):

- A built-in SSH client, or a key manager.
- File transfer (drag and drop to a remote pane, `scp` integration).
- Port forwarding.
- X11 forwarding.
- Keeping a connection through a change of IP address, as mosh does. The app
  connects again instead.
- Sessions shared by more than one user.
- Windows hosts.

## 4. User experience

### 4.1 Starting a remote session

- **Profile.** A profile gets a "Run on" setting: "This Mac" or "Remote host".
  For a remote host, the profile has a destination: an ssh destination
  (`user@host`, or a `Host` alias from `~/.ssh/config`). A remote profile
  always starts persistent sessions. Its environment variables apply on the
  remote host (see 7.1).
- **Command.** File > New Remote Session (⇧⌥⌘T) asks for a destination. It
  shows recent destinations and the `Host` entries of `~/.ssh/config`. The
  list follows `Include` lines. It does not show patterns (`Host *`,
  `Host *.example.com`) or `Match` blocks. The command uses the default
  profile for appearance, but not the environment variables of that profile.
- **Splits.** A split of a remote pane starts a new session on the same host,
  in the same directory. The shell reports the directory with OSC 7 (shell
  integration, see 7.1). When the shell does not report it, the helper reads
  the directory of the shell process (`/proc/<pid>/cwd` on Linux,
  `proc_pidinfo` on macOS).
- **New Tab and New Window.** See Q14.

### 4.2 Connection states

The pane shows the state in a banner, like the local banner for a stopped
helper:

| State | Banner | Actions |
|---|---|---|
| Connecting | "Connecting to host…" | Cancel |
| Confirm install | "Tecolot will install its helper (12 MB) in ~/.tecolot on host." (see 4.6) | Install, Cancel |
| Installing | "Installing the Tecolot helper on host (12 MB)…" with progress | Cancel |
| Authenticating | ssh prompt in a sheet (password, passphrase, OTP, host key, security key) | Enter, Cancel |
| Connected | no banner | |
| Reconnecting | "Connection lost. Reconnecting… (attempt 3)" | Reconnect now, Close |
| Sign-in needed | "Reconnecting to host needs your password." (see 7.3) | Sign In, Close |
| Other machine | "This session runs on login3. host.example.com connected to login1." (see 7.3) | Retry, Close |
| Failed | the ssh error in plain words, and the ssh log | Retry, Close |
| Session ended | "The shell exited with status N." | Close |

- While the pane is not connected, it shows the last screen that it received,
  dimmed. Typing is not possible. Scrolling works in the rows that are in the
  cache.
- All panes of a host share one connection (5.1). Each pane shows the state
  of that connection. Cancel in a pane closes that pane. It stops the
  connection only when no other pane uses it.
- After an authentication error or a host key error, Failed does not retry
  by itself (7.3). For a changed host key, the banner shows the ssh message
  and the `ssh-keygen -R <host>` command. It has no action that accepts the
  new key.

### 4.3 Prompts from ssh

The app is not a terminal for `ssh` itself. Prompts go through
`SSH_ASKPASS`:

- Tecolot sets `SSH_ASKPASS` to a small tool in the app bundle and
  `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4 or later; `/usr/bin/ssh` is
  newer).
- The app also sets `TECOLOT_ASKPASS_TOKEN`, a random value for each ssh
  process. The tool sends the token and the prompt to the app, through a
  socket in the private runtime directory. The app rejects a prompt with an
  unknown token. The token also tells the app which connection asks.
- The app shows the prompt as a sheet on a window that has a pane on that
  host: the key window if it has one, else the frontmost such window. It
  shows one prompt at a time.
- The sheet shows the host name, and the last lines that ssh wrote on stderr.
  Servers with two-factor login (for example Duo) write their instructions
  there, before the prompt.
- **Security keys.** When a key needs a touch, ssh starts the tool with
  `SSH_ASKPASS_PROMPT=none` and stops the tool after the touch. The app shows
  "Touch your security key for host" without a text field, and removes it
  when the tool exits.
- **Host keys.** Host key prompts ("Are you sure you want to continue
  connecting") use the same path, with the fingerprint shown clearly. The app
  never answers a host key prompt by itself. Note: ssh itself accepts a new
  host key without a prompt when the user's config has
  `StrictHostKeyChecking accept-new` or `no`. The app does not change this
  setting.
- The app never stores passwords. Keys and the agent are the normal way.

### 4.4 Session list

Attach to Session shows one section for this Mac and one section for each
host that has remote profiles or recent destinations. A host section lists
its sessions only after the user expands it or after a connection exists, so
that opening the list does not connect to every host.

- The app identifies a host by the user, host name and port that
  `ssh -G <destination>` reports, not by the destination text. Two aliases
  for the same account show as one section.
- The helper also reports a machine identity (7.3). Some names go to more
  than one machine (for example a load balancer in front of `login1` to
  `login4`). The list then shows the sessions of the machine that the
  connection reached. Sessions on other machines show from the app's records,
  marked "on login3". The user can attach to them only through a connection
  that reaches that machine, for example with a `Host` alias for each
  machine.

### 4.5 Differences from local persistent panes

- File drop: off. A drop shows "Files cannot be dropped into a remote
  session."
- "Show in Finder" for the working directory: off.
- Job icons: on. The remote helper reports process names (from `/proc` on
  Linux); icons that need a local path fall back to the generic icon.
- Clipboard (OSC 52): writes work as in local panes. For reads of the Mac
  clipboard by a remote program, see Q15.
- Links: `http` and `https` links open as in local panes. A `file://` link
  opens only when its host name is the name of this Mac. A `file://` link
  with the remote host name never opens a local file.
- Images: on. Large images can be slow on a slow link (see 7.4).

### 4.6 First install and removal

- The first install on a host shows a confirmation in the pane: "Tecolot will
  install its helper (12 MB) in ~/.tecolot on host. The helper runs your
  shell, so that the session continues when you disconnect." Actions:
  Install, Cancel. The app keeps the answer for each host. Later updates of
  the helper on that host do not ask again (see Q16).
- **Remove Tecolot from Host…** is a command on each host section of the
  session list. After a confirmation, it terminates the sessions on that
  host, then runs `tecolot-sessiond uninstall`. The command removes
  `~/.tecolot` and the runtime directory of the host (7.6). The documentation
  also gives the manual steps.

### 4.7 Restore after relaunch

- Restore brings back remote panes in the "Reconnecting" state, with the
  host name.
- The app connects to a host when a window with a pane on that host becomes
  visible, not at launch. There is one connection per host, thus one login
  per host. When more than one host needs a prompt, the app shows the
  prompts one at a time.

## 5. Architecture

```
 Tecolot.app                                     remote host

 HostLink (one per host)
   ssh master (-M -N)  ═══ one ssh connection ═══▶ sshd
     ssh -S … /bin/sh -s           (probe)    ───▶   /bin/sh -s              (ends)
     ssh -S … /bin/sh …/receive    (install)  ───▶   /bin/sh …/receive       (ends)
     ssh -S … …/tecolot-sessiond bridge --stdio ◀═▶  tecolot-sessiond bridge --stdio
                                                       channel 0: directory
 RemoteSession (pane A) ◀── channel n ──────────────▶  channel n ─▶ <A>.sock ─▶ serve (A)
 RemoteSession (pane B) ◀── channel m ──────────────▶  channel m ─▶ <B>.sock ─▶ serve (B)
```

- **One connection per host.** The app has one `HostLink` per host. It starts
  one ssh master process, which logs in once. Each step after that is a short
  ssh client process that opens a new channel on the master's connection. It
  does not log in again (5.1). All panes on the host share the connection. A
  new pane on a connected host opens at once.
- **The bridge.** On the remote host, a client of the master runs
  `.tecolot/bin/<os>-<arch>/<release>/tecolot-sessiond bridge --stdio`. The
  bridge reads framed messages on stdin and writes them on stdout. It
  connects each channel to the Unix socket of one session, on the remote
  host.
- **Sessions are the same as local sessions.** The bridge starts sessions with
  the same `serve` code. A session does not know that its client is remote.
  When the link drops, the bridge exits; the sessions continue.

### 5.1 The shared connection

OpenSSH can share one authenticated connection between many ssh processes
(connection multiplexing, `ControlMaster`). The first process, the master,
makes the connection and listens on a Unix socket, the control socket. Each
later `ssh -S <control socket> <destination> <command>` sends its command
through the master. It opens a new channel on the existing connection in
about one round trip. There is no new login and no new TCP connection.

Tecolot uses this as follows:

1. **A private master.** The app starts the master as its own child process:
   `ssh -M -N -S <control socket> -o ControlPersist=no … <destination>`
   (all options in 5.2). Options on the command line take precedence over
   `~/.ssh/config`. Thus the master works when the user's config does not
   use multiplexing, and it does not interfere with a master that the user
   has.
2. **The control socket.** The socket is in a 0700 directory in the app's
   private runtime directory: `<runtime>/ssh/<name>`. The app computes
   `<name>` as 16 hexadecimal digits of a hash of the user, host and port
   from `ssh -G`, and of the destination text. It does not use `%C`. A Unix
   socket path has a limit of 104 bytes on macOS, and ssh adds 17 bytes while
   it creates the socket. The app checks the length. When the path is too
   long, it uses `/tmp/tecolot-ssh-<uid>/` (mode 0700).
3. **Ready.** The master creates the control socket only after the login
   succeeds. The app waits for the socket, then checks the master with
   `ssh -S <control socket> -O check <destination>`.
4. **Clients.** Each step (probe, install, bridge) is a client:
   `ssh -S <control socket> -o ControlMaster=no -o BatchMode=yes
   -o ProxyCommand=false … <destination> <command>`. When the master is not
   there, a client usually makes its own connection. `BatchMode` prevents a
   prompt from that connection, and `ProxyCommand=false` makes it fail at
   once. The app then starts a new master.
5. **Connection options belong to the master.** Keepalive, compression,
   ciphers and proxy settings apply to the connection. The app sets them on
   the master. Session options (the command, agent forwarding, environment)
   apply to each client.
6. **One channel at a time.** The steps run one after the other: the probe
   channel closes before the install channel opens, and the install channel
   closes before the bridge starts. Thus a connection never has more than
   two session channels open: the bridge, and one short command. sshd limits
   the session channels per connection (`MaxSessions`, default 10). A server
   with `MaxSessions 1` works, because the app closes the bridge channel
   before it runs another command on that server.
7. **Servers without multiplexing.** Some gateways refuse a second session
   channel on a connection, also after the first one closed ("open failed:
   administratively prohibited"). The app then runs each step as its own
   connection, with its own login. This is slower and can show more prompts.
   The app remembers this for the host.
8. **Lifetime.** The master runs while the host has panes. After the last
   pane on the host closes, the app keeps the master for 5 minutes, so that a
   new pane opens at once. Then it stops the master with `-O exit`. When the
   app quits, it stops all its masters (see Q10). A master that a crashed app
   leaves behind continues to run. At the next launch, the app finds it in
   its runtime directory, uses it again if `-O check` succeeds, and applies
   the same rules.
9. **Drops.** When the network drops, the master and all its channels end. A
   new connection needs a new login. Multiplexing does not remove that login.
   Keys in the agent make it silent.
10. **The user's own master.** When `ssh -G` reports a `controlpath` for the
    destination and `-O check` on that path succeeds, the user already has a
    connection, for example from another terminal. The app can use it with
    no prompt at all. The risks: the user can stop it with `ssh -O exit`, its
    keepalive settings are the user's, and when the app finds a hung link
    through it, the app must not stop it (it starts its own master instead).
    See Q11.

### 5.2 The ssh command line

Before it connects, the app runs `ssh -G <destination>`. This command does
not use the network. It prints the effective configuration: user, host name,
port, `controlpath`, `forwardagent`, `serveraliveinterval`,
`serveralivecountmax`, `proxyjump` and `proxycommand`. (`Match exec` lines in
the config can run commands at this time, as they do for every ssh command.)

The master:

```
/usr/bin/ssh -M -N -S <control socket>
    -o ControlPersist=no
    -o ForkAfterAuthentication=no -o StdinNull=no   the app must own the process
    -o ClearAllForwardings=yes      forwards in the config take ports, or fail
    -o RemoteCommand=none -o RequestTTY=no
    -o PermitLocalCommand=no -o ForwardX11=no
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3   unless the config sets them
    -o Compression=yes
    <destination>
```

A client:

```
/usr/bin/ssh -S <control socket> -T
    -o ControlMaster=no -o BatchMode=yes -o ProxyCommand=false
    -o SessionType=default -o StdinNull=no -o ForkAfterAuthentication=no
    -o RemoteCommand=none -o RequestTTY=no -o PermitLocalCommand=no
    [-A]                            bridge only, when ssh -G says forwardagent yes
    <destination> <command>
```

- The environment of each ssh process has `SSH_ASKPASS`,
  `SSH_ASKPASS_REQUIRE=force` and `TECOLOT_ASKPASS_TOKEN` (4.3). For `PATH`
  and `SSH_AUTH_SOCK`, see Q12.
- The app reads stderr of each ssh process through a pipe. It uses the text
  for prompts (4.3), for the error classes (7.3), and for the log (8).
- `<command>` has only the characters `A–Z a–z 0–9 . / _ -` and spaces. ssh
  gives the command line to the user's login shell, which can be fish, tcsh
  or nushell. These shells do not agree on quotes, `$`, `~`, `;` or `&&`.

### 5.3 Framing on the link

Each message on the link is `[u32 length][varint channel][payload]`.

- **Channel 0** is the directory channel. Its payload is one message in the
  session envelope format. It carries `ListSessions`,
  `CreateSession{launch}`, `TerminateSession{id, signal}`,
  `OpenChannel{session id} → channel n`, `CloseChannel{n}`,
  `HelperInfo{build, os, arch, machine, host name}`, `Ping`, `Pong` and the
  flow-control messages of 7.4. Launches and records are the existing JSON
  types (`SessionLaunch`, `SessionRecord`) inside a binary envelope.
- **Channel n** (n ≥ 1) is one attached pane. Its payload is a chunk of the
  byte stream between the pane and the session socket. The bridge does not
  decode it, and a chunk can start or end inside a session message. A chunk
  has at most 16 KB, so that the bridge can send chunks of different
  channels in turn.
- **Start marker.** Before the first message, the bridge writes one line:
  `TECOLOT-BRIDGE <protocol> <nonce>`. The app gives the nonce on the
  command line. The app ignores all bytes before this line, because startup
  files on the remote host can write text before the bridge starts.

### 5.4 Other designs that we considered

- **One ssh connection per pane.** It is simpler, but each pane then needs
  its own login, and a host with ten panes needs ten connections. The link
  per host also lets the app measure the round trip once and use it for all
  panes.
- **One ssh channel per pane** (a client of the master for each pane, which
  runs a relay to one session socket). ssh then does the multiplexing and the
  flow control for each channel, and the bridge needs no framing. But
  `MaxSessions` (default 10) limits the session channels of a connection, so
  a host could have at most about 9 panes.
- **Forwarded Unix sockets.** The master can forward each session socket to
  a local socket (`ssh -S <control socket> -O forward -L <local>:<remote>`).
  Then the pane connects to a local socket, as for a local session. Forwarded
  channels do not count against `MaxSessions`, and the data does not go
  through the bridge. But many servers turn forwarding off
  (`AllowStreamLocalForwarding no`, `DisableForwarding yes`, or `restrict` or
  `no-port-forwarding` on the key). Thus the bridge is necessary anyway. See
  Q19.

## 6. Installing the helper

### 6.1 Probe

The first client on a new connection runs:

```
/bin/sh -s
```

The app writes the probe script on the channel's stdin, then closes stdin.
All shell syntax is in the script, and only `/bin/sh` reads it (see 5.2 for
the reason). The app puts values into the script: the release, the expected
SHA-256 of each helper, and a random nonce. It allows only
`[A-Za-z0-9._-]` in these values.

The script writes its result between two marker lines:

```
TECOLOT-PROBE-BEGIN <nonce>
os=Linux
arch=x86_64
libc=glibc 2.35
host=login3
uid=1000
shell=/usr/bin/fish
home-ok=1
installed=<SHA-256 of the installed helper, or none>
runs=1
runtime=/tmp/tecolot-1000
runtime-ok=1
kill-user-processes=no
linger=no
TECOLOT-PROBE-END <nonce>
```

The app ignores all output outside the markers. Startup files (`.bashrc`,
`.zshenv`, `config.fish`, `.tcshrc`) run also for a command, and they can
write text. The markers keep that text out of the result.

Rules for each value:

- **os and arch** select the binary:

  | `uname -s` | `uname -m` | Binary |
  |---|---|---|
  | Linux | `x86_64`, `amd64` | `linux-x86_64` |
  | Linux | `aarch64`, `arm64` | `linux-aarch64` |
  | Darwin | `arm64`, `x86_64` | `darwin-universal` |
  | other | other | "This host is not supported (os, arch)." |

  32-bit systems (`armv7l`, `i686`) are not supported. FreeBSD and others
  can come later.
- **libc** comes from `getconf GNU_LIBC_VERSION`. Otherwise it is `musl` or
  `unknown`. With the static build (6.4), the helper does not depend on it,
  and the app only logs it. With a glibc build, the app refuses a host with
  an older glibc than the build needs (Q13).
- **shell** is the login shell of the user, from `getent passwd`, or from
  `$SHELL`. The app logs it.
- **home-ok** is 1 when `~/.tecolot` exists or can be created, belongs to
  the user, and other users cannot write to it. Otherwise the app shows
  Failed (see Q9).
- **installed** is the SHA-256 of
  `~/.tecolot/bin/<os>-<arch>/<release>/tecolot-sessiond`, which the script
  computes on each connection (about 0.1 s for 30 MB). It uses `sha256sum`,
  `shasum -a 256` or `openssl dgst -sha256`. When none is available, the
  app shows Failed.
- **runs** is 1 when the installed helper answers `version --json`.
- When `installed` equals the expected hash and `runs` is 1, the app starts
  the bridge. Otherwise it installs (6.2).
- **runtime** and **runtime-ok**: the script computes `/tmp/tecolot-<uid>`
  (7.6) and creates it with mode 0700 when it is missing. `runtime-ok` is 1
  when the directory is not a symbolic link, belongs to the user, and has
  mode 0700.
- **kill-user-processes** and **linger** come from `loginctl` (7.7). On
  hosts without systemd, they are empty.

### 6.2 Upload

The upload needs its own channel. The probe channel cannot carry the binary
after the script: dash, the `/bin/sh` of Debian and Ubuntu, reads ahead on
stdin. The bytes after the script then do not reach the command that reads
them. (Tested: with dash, `x=$(head -c 5)` followed by data on stdin gives
an empty value; bash, zsh and ksh give the data.)

1. When the installed hash is not the expected hash, the probe script also
   creates `~/.tecolot/tmp/<nonce>/` (mode 0700) and writes a short receiver
   script, `receive`, in it.
2. The app runs a second client: `/bin/sh .tecolot/tmp/<nonce>/receive`. The
   path is relative to the home directory, where sshd starts the command.
   The app writes the gzip-compressed helper on stdin, closes stdin, and
   shows progress from the bytes that it wrote.
3. The receiver:
   1. copies stdin to its end into `upload.gz`;
   2. unpacks it with `gzip -dc`;
   3. checks the SHA-256 of the unpacked binary against the expected value;
   4. sets the mode to 0700;
   5. runs `./tecolot-sessiond version --json`, to find a home directory
      that does not allow programs to run (`noexec`), or a wrong
      architecture;
   6. renames the directory into place as
      `~/.tecolot/bin/<os>-<arch>/<release>/`;
   7. writes the hash file, and removes `tmp/<nonce>`.

   For each step, the receiver writes one line with the nonce. When a step
   fails, the app shows the step in plain words, for example "The home
   directory does not allow programs to run (noexec)" or "There is not
   enough disk space on host".
4. When `gzip` is not available, the app uploads the binary without
   compression (the ssh compression of 5.2 still applies).

Rules:

- **Unique names.** Each temporary file and directory has the nonce in its
  name. Two Macs that install at the same time use different temporary
  directories. The final rename is atomic, because it stays in the same file
  system. When the rename fails because the other Mac was first, the
  receiver checks the hash of the directory that is there, and uses it.
- **The install path.** `<release>` is `<version>-<first 8 digits of the
  hash>`. Two builds with the same version (for example debug builds) do not
  overwrite each other, and an install never replaces a binary that a
  session uses. `<os>-<arch>` is in the path because some home directories
  are shared over NFS by machines with different architectures.
- **Shared files.** The helper contains the terminfo entries and the
  shell-integration scripts. The bridge writes them to
  `~/.tecolot/share/<release>/` when they are missing. Thus there is one
  upload, and the host needs no `tar`.
- The upload never uses `sudo`, and never writes outside `~/.tecolot` and
  the runtime directory (7.6). The app refuses to install when `~/.tecolot`
  belongs to another user or other users can write to it.

### 6.3 Old versions

- The helper of each running session stays in place: a session runs its own
  binary until it ends.
- A home directory on NFS can be shared by more than one machine, and a
  bridge sees only the sessions of its own machine (7.6). Thus each helper
  touches `in-use/<machine>` in its version directory once a day while it
  runs.
- On each connection, the bridge removes the versions in
  `~/.tecolot/bin/<os>-<arch>/` that are older than the current one by more
  than one release and that have no `in-use` file younger than 7 days.
- The bridge reports the helper build of each session in `ListSessions`. The
  app supports old helpers for a limited number of releases (Q20). For a
  session outside that window, the pane shows "This session uses an old
  helper. You can terminate it." and offers Terminate Session.

### 6.4 Binaries in the app

- Proposal: build the Linux helpers fully static with the Swift Static Linux
  SDK (musl), for x86_64 and aarch64. A static binary does not depend on the
  glibc of the host. It works on Alpine, and on a 64-bit kernel with a 32-bit
  user space. The speed of the musl allocator on the frame path needs a
  measurement (Q13).
- CI builds the Linux helpers, strips them, and compresses them with gzip.
- The SHA-256 of each binary (not of the compressed file) is in a plist in
  the app bundle. The app's code signature covers the plist, so the hashes
  are trusted.
- Size estimate: 25–40 MB each before compression, 8–14 MB after. To be
  measured (see Q5).
- macOS remote hosts use the helper that the app already contains. It links
  only system frameworks and system libraries (`otool -L`), so it runs when
  it is copied alone. The release build must be universal (arm64 and
  x86_64); the debug build is arm64 only.

### 6.5 Removal

`tecolot-sessiond uninstall` (see 4.6) removes `~/.tecolot` and the runtime
directory, after the app has terminated all sessions on the host. It does
not remove the `~/.terminfo` entries of 7.1, because other programs can use
them.

## 7. Behavior on the link

### 7.1 Remote environment

The remote shell gets a login environment from the remote host, not the
Mac's.

- **The launch is different.** A local `SessionLaunch` has the full path of
  the program and the complete environment, which the app makes from the
  Mac's environment (`TerminalEnvironment.base`). A remote launch has:
  - no program path: the bridge uses the remote user's login shell (from
    `getpwuid`), started as a login shell. When the profile has a command,
    the login shell runs it with `-c`;
  - only the variables that the app sets: `TERM`, `COLORTERM`,
    `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERM_FEATURES`, the locale (see
    below), and the variables of a remote profile.
- **The base environment** is the environment of the bridge, which sshd and
  PAM gave to the ssh session (this includes `/etc/environment` on many
  hosts), without `SSH_TTY` and without the variables of the bridge itself.
  `SSH_CONNECTION` and `SSH_CLIENT` keep the values of the connection that
  created the session. They do not change after a reconnect.
- **Profile variables.** The variables of a remote profile apply after the
  base environment. New Remote Session does not apply the variables of the
  default profile, because they are written for the Mac (for example a
  `PATH` with `/opt/homebrew/bin`).
- **Shell integration** works as for local panes (`ZDOTDIR` for zsh, and the
  files for bash and fish), with paths in
  `~/.tecolot/share/<release>/shell-integration/`. The bridge sets these
  paths, because only the bridge knows the remote home directory. (Local
  panes use paths in the app, see `TecolotShellIntegration.swift`.)
- **TERM.** Proposal: the default `TERM` on remote hosts is `xterm-256color`.
  When a profile selects another `TERM`, the helper writes its entry to
  `~/.terminfo` (in the letter and in the hexadecimal directory layout). It
  writes only missing entries, and never replaces an entry. ncurses reads
  `~/.terminfo` without a variable, so the session does not set `TERMINFO`.
  Limits: `sudo` with another home directory, and ssh to a third host, do
  not find the entry. See Q17.
- **Locale.** `LANG` and `LC_*` come from the Mac, as `ssh` `SendEnv` does,
  when the remote host accepts them (see Q3). An app opened from the Dock
  has no locale variables, so the app takes the locale from the system
  settings of the Mac.
- **Agent forwarding.** Proposal: the bridge client requests agent
  forwarding (`-A`) only when `ssh -G` reports `forwardagent yes` for the
  destination. The bridge then keeps a fixed path,
  `<runtime>/agent.sock`, as a symbolic link to the forwarded agent socket of
  the newest connection. Sessions get `SSH_AUTH_SOCK=<runtime>/agent.sock`.
  After a reconnect, the link points to the new socket. While the link is
  down, the agent is not available. See Q18.
- **Working directory.** It is the remote home, or the directory of the pane
  that was split.
- **Colors.** The session answers color queries (OSC 4, 10, 11) with the
  theme of the launch. With two Macs that use different themes (7.5),
  programs see the colors of the Mac that created the session. Proposal: use
  the theme of the client that typed last, as for the size.

### 7.2 Keepalive and drop detection

- The app sets `ServerAliveInterval=15` and `ServerAliveCountMax=3` on the
  master, unless `ssh -G` shows other values from the user's config.
- The link also sends `Ping` on channel 0 every 10 seconds when it is idle.
  All data that arrives on the link shows that the link is alive. `Ping` and
  `Pong` go before all other data in both directions, so that a large
  transfer cannot delay them. When nothing arrives for 30 seconds, the app
  treats the link as dropped, stops the master, and reconnects.
- The bridge exits when nothing arrives from the app for 60 seconds. This
  ends bridges whose connection is dead but which sshd has not detected yet.
- After a wake from sleep, or after a network change (Network framework path
  update), the app sends a `Ping` at once and waits 3 seconds for data. When
  nothing arrives, it reconnects. A short sleep then does not cost a new
  login.

### 7.3 Reconnecting

- **Error classes.** ssh exits with status 255 for all connection errors.
  The app reads the stderr text:

  | ssh message | Action |
  |---|---|
  | Connection timed out, Connection refused, Network is unreachable, No route to host, Could not resolve hostname, Connection reset, Broken pipe | Retry with backoff |
  | Permission denied, Too many authentication failures | Failed, no retry |
  | REMOTE HOST IDENTIFICATION HAS CHANGED, Host key verification failed | Failed, no retry, no action that accepts the key |
  | The user cancels a prompt | Failed, no retry |
  | Other text | Failed, Retry available |

  Automatic retries after authentication errors would show a prompt on each
  attempt. They can also make tools such as fail2ban block the Mac's
  address.

  The retry row applies after the connection to the host succeeded once, or
  when a pane waits for a session that exists (as after a relaunch, 4.7).
  Before that, these errors are "Failed, Retry available", so that a wrong
  host name shows its error at once.
- **Backoff.** Retries use backoff: 1, 2, 4, 8, 15 seconds, then every 30
  seconds while the pane is open, and only while the Mac has a network path.
  "Reconnect now" retries at once.
- **Prompts during a reconnect.** When a reconnect needs a prompt (password,
  OTP, security key) and the app is not active, the app cancels the prompt.
  The pane then shows "Sign-in needed" and waits for the user.
- **Attach again.** After the reconnect, each pane attaches again.
  `SetViewport` carries the row versions that the pane has, so the helper
  sends only the rows that changed while the pane was away.
- **Client identity.** `Hello` gets a client instance ID: a random value for
  each pane, which does not change across reconnects. When a client attaches
  with an ID that already has an attachment, the session closes the old
  attachment. This removes the attachments of bridges whose connection died.
  (Today `Hello` has no such field.)
- **Machine identity.** `HelperInfo` contains a machine ID (`/etc/machine-id`
  on Linux, `gethostuuid` on macOS) and the host name. The app stores it with
  each remote session. When a reconnect reaches another machine (for example
  through a load balancer), the pane shows "Other machine" and does not
  attach.
- If the session ended while the link was down, the pane shows the exit
  status.

### 7.4 Latency and flow control

Measurements on a local link (see the latency exploration in the plan): the
protocol adds about 0.2–0.4 ms to a keystroke and about 1 ms to a Ctrl-C
during a flood. On a remote link, the round trip (RTT) dominates.

- **Frame window.** Today a client can have 2 frames in flight. On a link
  with a 100 ms RTT, that allows 20 frames per second, and after a burst the
  first frame can wait one RTT. The helper should size the window from the
  measured RTT and bandwidth: enough frames to fill one RTT, at most 8.
- **Bytes in flight.** On a local socket, a session can have up to 4 MB in
  flight for each client (`SessionClient.byteBudget`). On a link, the data
  that ssh and TCP hold waits in front of the next frame: 4 MB at 1 MB/s is
  4 seconds. Three rules:
  1. The app tells each session the limits for its link: frames and bytes
     in flight, from the measured RTT and bandwidth (about bandwidth × RTT,
     at least 64 KB). This is a new message, `SetFlowLimits`, which the app
     sends again when the measurements change.
  2. The bridge limits the bytes that it wrote to ssh and that the app did
     not acknowledge yet, for all channels together (the link window, about
     2 × bandwidth × RTT). The app sends `LinkAck{bytes}` on channel 0.
  3. The bridge uses a small receive buffer on each session socket (for
     example 32 KB). Waiting data then stays in the session's own queue,
     where frames go before bulk data, and not in the socket.
- **Upstream.** Each channel has a receive window in the bridge (for example
  256 KB). The app sends no more to a channel than its window. The bridge
  gives credit back when the session reads the data. A large paste in one
  pane cannot delay the keys of another pane, and the bridge never stops
  reading stdin.
- **Input boost.** Input already makes the next frame bypass the frame-rate
  limit. On a remote link, the frame with the echo also needs a free credit:
  the helper keeps one credit free for the frame that follows input.
- **Local echo (prediction).** On links with an RTT above about 50 ms, the
  pane can show typed characters before the helper confirms them, as mosh
  does: draw them underlined at the cursor, and remove them when the frame
  with the real echo arrives. The pane only predicts when the program echoes
  (not after a password prompt, not in the alternate screen with unknown
  behavior). This is a separate step after the first release (see Q6).
- **Bulk data.** Scrollback rows, search results and images go on the bulk
  queue behind frames, as today. On a slow link, an image larger than 4 MB is
  sent scaled down to the pane's size first, and the full image only when
  the user scrolls to it (see Q7).
- **Compression.** The first release sets `Compression=yes` on the master. A
  later release can compress bulk messages with zstd, behind the existing
  `compressed` envelope flag.

### 7.5 Multiple Macs

Two Macs can attach to the same remote session. The existing rules apply: the
client that typed last owns the size, and the other client shows the screen
letterboxed. Each Mac uses its own theme (for color queries, see 7.1).

Each Mac runs the bridge of its own release. The Macs can have different
Tecolot releases, so a Mac can be older than the helper of a session. The
`Hello` versions decide. When the two ends have no common protocol version,
the pane shows "This session uses a newer helper. Update Tecolot to attach."
Changes to `SessionRecord` must only add fields, because a bridge reads
records that other releases wrote.

### 7.6 Runtime directory on the remote host

- **Path.** The bridge uses `/tmp/tecolot-<uid>`, computed from the uid
  only, and gives it to every helper with `--runtime-dir`. It does not use
  `$XDG_RUNTIME_DIR`, for two reasons:
  - systemd-logind removes `/run/user/<uid>` when the last login of the user
    ends, unless linger is on. The shells continue to run, but their sockets
    and records are gone.
  - Some ssh logins do not set `XDG_RUNTIME_DIR`. Two logins could then use
    two different directories.

  The Linux branch of `RuntimeDirectory.defaultLocation()` (today
  `$XDG_RUNTIME_DIR/tecolot`) changes to the same rule.
- **Checks.** The directory must belong to the user, have mode 0700, and not
  be a symbolic link (`RuntimeDirectory.prepare` already checks this). When
  it belongs to another user, the app shows Failed with the path.
- **Cleanup of `/tmp`.** systemd-tmpfiles removes old files in `/tmp` (often
  after 10 days without access). The helper touches its socket, record and
  log once an hour. When a socket is missing, the bridge sends SIGUSR1 to
  the helper (the pid is in the record), and the helper creates its socket
  again, as tmux does.
- **macOS.** macOS also removes old items from the per-user temporary
  directory (`$TMPDIR`), which local sessions use. Find out whether this
  removes the sockets of local sessions that run for more than 3 days. The
  same touch rule fixes both cases.
- Records and sockets are always on the machine, never in the home
  directory, which other machines can share.

### 7.7 Process lifetime on the remote host

- The helper detaches as it does on the Mac: a second copy in a new session
  (setsid), with stdin from `/dev/null` and its output in the log.
- **No inherited descriptors.** No descriptor of the bridge may reach a
  helper or a shell. On macOS, `POSIX_SPAWN_CLOEXEC_DEFAULT` does this
  (`SessionDirectory.spawn`). Linux has no such flag. If a session holds a
  descriptor of the ssh channel, sshd does not close the channel when the
  bridge exits, and the connection hangs. On Linux, the spawn must close all
  descriptors above 3 (for example with
  `posix_spawn_file_actions_addclosefrom_np` on glibc 2.34 or later), or set
  `FD_CLOEXEC` on all descriptors before the spawn.
- **systemd.** The probe reads `KillUserProcesses` and `KillExcludeUsers`
  (`loginctl show-user` without a user name shows the properties of the
  manager) and `Linger` (`loginctl show-user <user>`). When
  `KillUserProcesses` is yes, the user is not excluded, and linger is off,
  logind ends all processes of the user at the last logout. The app shows:
  "This host ends your sessions when you log out. Run `loginctl
  enable-linger` to keep them." The app does not change the setting. Most
  distributions set `KillUserProcesses=no`.
- With `RemoveIPC=yes` (the default), logind also removes the System V and
  POSIX IPC objects of the user at the last logout. The helper must not keep
  long-lived state in them.

## 8. Security

- The link is ssh. Tecolot adds no network listener on either side.
- While the master runs, its control socket gives access to the remote
  account without a login. The socket is in a 0700 directory in the app's
  runtime directory. Other processes of the same Mac user can use it. The
  same is true for a ControlMaster of the user, and for the ssh agent. For
  how long masters stay, see 5.1 and Q10.
- Session sockets on the remote host are in a 0700 directory,
  `/tmp/tecolot-<uid>` (7.6). The helper checks the peer uid of every
  connection (`getpeereid` on macOS, `SO_PEERCRED` on Linux; both exist in
  `UnixSocket.peerUID`).
- The probe computes the SHA-256 of the installed helper on each connection.
  The app compares it with the hash in its signed plist. When the hashes are
  different, the app installs again. A process that runs as the same remote
  user can change the helper between the check and the start. The check
  finds damaged and old installs, not attacks by the same user.
- Each ssh process has its own askpass token (4.3). Prompts from ssh are
  shown as they are, with the host name. The app never answers them by
  itself. It cancels the prompts of an automatic reconnect while the app is
  not active (7.3).
- The first install on a host needs the user's confirmation (4.6).
- The app logs ssh's stderr per host in the runtime directory, for the
  "Failed" banner. It does not log keystrokes, screen content or the answers
  to prompts.

## 9. Remote host requirements and limits

- Linux on x86_64 or aarch64. With the static build (6.4), any C library;
  with a glibc build, glibc 2.31 or later (to be confirmed by the CI image).
- macOS 15.5 or later (the deployment target of the helper).
- A POSIX `/bin/sh`, and these programs: `uname`, `id`, `mkdir`, `chmod`,
  `mv`, `rm`, `cat`; `sha256sum`, `shasum` or `openssl`; `gzip` (without it,
  the upload is not compressed).
- A home directory that the user can write to, on a file system that lets
  programs run (not `noexec`). See Q9.
- sshd must allow session channels (`MaxSessions` 1 or more). Servers that
  refuse a second channel on a connection need one login for each step
  (5.1).
- systemd hosts: see 7.7 for `KillUserProcesses` and linger.
- iTerm2 images on Linux helpers need a PNG and JPEG decoder (the macOS
  helper uses ImageIO). Sixel and Kitty images work without one (see Q8).

## 10. Changes by component

| Component | Change |
|---|---|
| TecolotWire | Link frames with channels; `LinkAck` and channel credits; `SetFlowLimits`; a client instance ID in `Hello`; `HelperInfo{build, os, arch, machine, host name}`. |
| TecolotTransport | A channel that looks like a `MessageChannel` to `RemoteSession`. The Linux runtime directory changes to `/tmp/tecolot-<uid>`. |
| TecolotSessionDaemon | `bridge --stdio` with its start marker; channel 0 directory commands; flow control for each channel and the link window; idle timeout; the agent socket link; the remote launch (login shell, base environment); writes the shared files; `uninstall`; cleanup of old versions with `in-use` files. |
| TecolotSessionHost | Frame and byte limits from `SetFlowLimits`; one credit kept free after input; close the old attachment of a client instance ID; touch the socket and the record; SIGUSR1 creates the socket again; the cwd of the shell for splits. |
| Linux port | Build the package on Linux, in CI, from milestone 1. Known gaps: image decoding without ImageIO (`SessionImages.swift`, Q8); close the inherited descriptors in the spawn (7.7); SwiftTerm without AppKit. Already present: `SO_PEERCRED`, `/proc` for process names, SIGPIPE ignored. |
| TecolotSessionClient | `RemoteSession` over a channel; reconnect with known row versions; the client instance ID. |
| App | `HostLink`: `ssh -G`, the master and its clients, probe, install, error classes, reconnect, keepalive. The askpass tool with its token, prompt sheets, the security key notice. Profile "Run on"; New Remote Session; the session list per host and machine; banners with the new states; the first-install confirmation; Remove Tecolot from Host; restore without connections at launch. |
| CI | Static Linux helper builds, checksums into the plist, a test job with an sshd container. |

## 11. Testing

- Unit: link framing (fuzzing, truncated messages), flow control and
  credits, directory commands, the reconnect state machine with a fake
  transport, the error classes (with stderr samples from OpenSSH), and the
  probe parser with text before and after the markers.
- Integration on the Mac: `ssh localhost` with a test key. Remote Login is
  off on CI runners; the job turns it on
  (`sudo systemsetup -setremotelogin on`) and adds the key. Install from
  scratch, upgrade, a corrupt upload, two apps installing at once.
- Linux: containers with sshd and a test user; the same integration suite,
  and also:
  - startup files that write text (`.bashrc`, `.zshenv`, `config.fish`);
  - fish, tcsh and zsh as login shells;
  - dash as `/bin/sh` (Debian), and BusyBox (Alpine);
  - a home directory mounted `noexec`, and a full disk;
  - `MaxSessions 1`, forwarding off, agent forwarding on;
  - a user config with `ControlMaster auto` (with and without
    `ControlPersist`), `RemoteCommand`, and `LocalForward`;
  - logout with linger off, with `KillUserProcesses` yes and no;
  - systemd-tmpfiles cleanup of the runtime directory (with a short age);
  - one home directory shared by two containers.
- Faults: kill the master; stop it (`SIGSTOP`) to simulate a hung link; kill
  only the bridge; delay packets with a delay proxy (`pf`/`dnctl`, or a TCP
  proxy in the test) at 50, 150 and 300 ms RTT, with a 1 MB/s bandwidth
  limit. Check the echo time and the Ctrl-C time against the targets, also
  while a large image goes to another pane.
- Latency targets (to agree on): keystroke echo within RTT + 5 ms at p50;
  Ctrl-C during a flood within 2 × RTT + 20 ms at p90.

## 12. Milestones

1. Bridge and link framing over a private master; `ssh localhost` with a
   helper that is already installed; attach, detach, reconnect by hand. CI
   builds the package on Linux.
2. Probe and install (macOS hosts first, then static Linux builds in CI); the
   remote runtime directory; process lifetime rules.
3. Profiles, New Remote Session, session list per host, banners, askpass and
   prompts, first-install confirmation, Remove Tecolot from Host.
4. Automatic reconnect with error classes, keepalive, sleep and network
   change handling, client instance ID, machine identity.
5. Flow limits from RTT and bandwidth, the link window and channel credits,
   the free credit after input; latency tests with delay and bandwidth
   limits.
6. Later: local echo prediction, zstd for bulk data, scaled images on slow
   links, forwarded sockets (Q19).

## 13. Open questions for the design group

- **Q1. Where does a remote destination live?** In profiles only, in a
  separate "Hosts" list, or both? Profiles mix appearance with location; a
  host list makes "the same look on every host" easy.
- **Q2. Upload channel.** Resolved: the upload is its own channel on the
  shared connection (5.1, 6.2). It needs no second login.
- **Q3. Locale.** Send the Mac's `LANG`/`LC_*` (works only when the server's
  `AcceptEnv` allows it, otherwise set them in the launch), or use the remote
  defaults?
- **Q4. Session list cost.** Is listing remote sessions on demand acceptable,
  or should the app keep links to recent hosts open in the background?
- **Q5. Binary size.** Is a 10–14 MB download per helper version acceptable on
  slow links? Options: a smaller build without Foundation, or downloading from
  a Tecolot URL on the remote side when it has internet access.
- **Q6. Local echo.** In the first release or later? It is the largest
  improvement on high-latency links and the largest risk of wrong display.
- **Q7. Images on slow links.** Scale down large images, or send them as they
  are and rely on the bulk queue?
- **Q8. iTerm2 images on Linux.** Add a decoder to the Linux helper (PNG at
  least), or decode in the app (send the file bytes and let the Mac decode)?
- **Q9. Hosts without a writable home** (for example some shared jump hosts).
  Support a temporary install in `/tmp`, or require a home directory?
- **Q10. Masters after quit.** Keep masters for some minutes after the app
  quits (as `ControlPersist` does), so that a relaunch needs no new login? It
  is faster. But a master that stays gives access without a login, and it
  removes the security-key touch that some users expect for each connection.
  Proposal: stop the masters when the app quits.
- **Q11. The user's own master.** Use a master from the user's config (5.1,
  item 10) to skip the login? Proposal: yes, behind a setting that is off by
  default.
- **Q12. The ssh program and its environment.** Allow another ssh, for
  example Homebrew's OpenSSH? Apple's ssh understands `UseKeychain`;
  Homebrew's ssh fails on it unless the config has `IgnoreUnknown`. Also, an
  app opened from the Dock has the `PATH` and `SSH_AUTH_SOCK` of launchd.
  Then `ProxyCommand` tools from Homebrew (`cloudflared`, `aws`, `gcloud`)
  are not found, and agents that the user sets in shell startup files
  (1Password, gpg-agent) are not used. Proposal: read `PATH` and
  `SSH_AUTH_SOCK` once from the user's login shell (`$SHELL -l -c env`, with
  a time limit), and use them for ssh.
- **Q13. Static musl or glibc build.** A static musl build removes the glibc
  limit and works on Alpine. The musl allocator is slower: measure the frame
  path, or link another allocator.
- **Q14. New Tab in a remote window.** Does New Tab (⌘T) or New Window (⌘N)
  in a window whose active pane is remote start a session on the same host,
  or a local shell? Proposal: the same host; the profile menu gives a local
  tab.
- **Q15. Clipboard reads from remote hosts.** OSC 52 lets a program read the
  Mac clipboard. For remote panes: ask each time, or off?
- **Q16. Consent for the first install.** Ask once per host (the proposal in
  4.6), or install without a question? Add a setting so that an
  organization can turn off the install?
- **Q17. Custom TERM on remote hosts.** Use `xterm-256color` on remote hosts
  (the proposal in 7.1), or the profile's `TERM` with an entry in
  `~/.terminfo`?
- **Q18. Agent forwarding.** Support it with the fixed socket link (the
  proposal in 7.1), or never forward the agent to persistent sessions?
- **Q19. Forwarded sockets.** When the server allows forwarding, the master
  could forward each session socket to a local socket (5.4). Each pane is
  then its own ssh channel, ssh does the flow control for each channel, and
  the data does not go through the bridge. The bridge is still necessary for
  servers that turn forwarding off, so this adds a second data path to test.
  Proposal: consider it only if measurements show that the bridge adds
  latency.
- **Q20. Compatibility window.** For how many releases must the app support
  old helpers? Sessions can run for months.
