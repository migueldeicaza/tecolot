# Hot-Reload Session Handoff (`SCM_RIGHTS`)

Status: prototype implemented on branch `hot-reload-session`.

## 1. Motivation & Goals

Tecolot supports two local pane architectures:

1. **Persistent panes (`tecolot-sessiond`)**: Each pane runs an out-of-process helper that owns the PTY and runs a headless SwiftTerm `Terminal` instance. These already survive app restarts, crashes, and upgrades, at the cost of a helper process (~5 MB base footprint) plus a duplicate scrollback buffer and IPC hop per pane (see `memory-usage-considerations.md`).
2. **Local in-process panes (`AppTerminalView`)**: The shell runs directly under `Tecolot` with zero IPC overhead and a single scrollback buffer, which is the default for users who did not opt into persistent sessions.

This design adds **in-place hot reload ("upgrade program in place")** for local in-process panes so that when a new version of `Tecolot` is installed (e.g., via Sparkle or a local build), the running `Tecolot` process can hand off all live local child shells and their PTY master file descriptors to the newly launched `Tecolot` process **without** using `tecolot-sessiond` and **without** paying any runtime memory or latency penalty during normal use.

### Goals

- Transfer live local PTY master file descriptors (`childfd`) from Process A (old `Tecolot`) to Process B (new `Tecolot`) over a private Unix domain socket using `SCM_RIGHTS`.
- Keep all running shells and child jobs alive with zero `SIGHUP`, zero lost bytes during handoff, and intact window/tab/split layout.
- Replace `LocalProcessChildReaper.wait()` (`waitid`/`waitpid`) with an exit-monitoring mechanism that continues to report accurate exit codes even after macOS (XNU) reparents the handed-off shells to `launchd` (PID 1).
- Support safe **rollback**: if Process B fails to start, crashes before acknowledging, or times out, Process A resumes all local panes without interrupting any running shell.
- Support **chained hot reloads** (`A -> B -> C`), including dormant tabs whose views have not yet been mounted.

### Prototype Scope & Non-Goals

- **No `SwiftTerm` fork required for the prototype**: The remote `SwiftTerm` package pin remains untouched; the prototype implements `HotReloadableLocalProcess` in Tecolot using `SwiftTerm`'s public `PseudoTerminalHelpers` and `TerminalView.feedSender`, and documents the minimal upstream `SwiftTerm.LocalProcess` APIs to add later (Section 7).
- **Normal-buffer scrollback + `SIGWINCH`**: The prototype reuses `RestoreStore` for window/tab/split layout and normal-buffer scrollback and sends `SIGWINCH` on attach. Full terminal emulator state serialization (alternate screen buffer, active mode flags, palette, Kitty graphics) is deferred to a follow-up milestone (Section 8).
- **App crashes**: Because this is a zero-overhead in-process handoff, it covers planned reloads and upgrades, not sudden crashes (which remain the domain of `tecolot-sessiond`).

---

## 2. macOS / XNU Process & PTY Mechanics

### Why `SCM_RIGHTS` Keeps Child Shells Alive

1. **No PTY hangup (`SIGHUP`)**: Passing a PTY master FD via `sendmsg(SCM_RIGHTS)` increments the kernel reference count on the underlying open file description. Process A closes its copy only *after* Process B acknowledges receipt, so the master refcount transitions `1 -> 2 -> 1` and never hits zero. The kernel therefore never delivers `SIGHUP` or EOF to the slave side.
2. **No orphaned process-group `SIGHUP`**: `forkpty()` places each shell in its own session (`setsid()`) with the PTY slave as its controlling terminal (`TIOCSCTTY`). Because the shell is a session leader outside Process A's session, Process A exiting does not orphan the shell's process group.
3. **Zero dropped bytes during handoff**: Process A pauses reading from `childfd` before snapshotting `RestoreStore` and transferring the FD. Any output written by the child during handoff remains queued in the kernel PTY buffer and is drained by Process B after it restores scrollback and attaches.

### The Kernel Parentage (`PPID`) Constraint

macOS (XNU) has **no process reparenting syscall** (nor Linux's `PR_SET_CHILD_SUBREAPER`). When Process A exits, XNU automatically reparents all of A's direct child shells to **`launchd` (PID 1)**.

| Operation in Process B after handoff | Behavior | Mechanism |
|---|---|---|
| PTY `read` / `write` | Works | Transferred `childfd` |
| Resize (`ioctl(TIOCSWINSZ)`) | Works | Transferred `childfd` |
| Foreground job, CWD, paste controls | Works | `tcgetpgrp(childfd)`, `tcgetattr(childfd)`, same-UID `libproc` |
| Signaling (`kill(shellPid, sig)`, `kill(-pgid, sig)`) | Works | Same effective UID |
| Zombie reaping | Automatic | `launchd` (PID 1) reaps automatically |
| **`waitid` / `waitpid`** | **Fails (`ECHILD`)** | `shellPid` is not a child of Process B |
| **Exit detection & exit status** | **Works** | `kqueue` `EVFILT_PROC` with `NOTE_EXIT \| NOTE_EXITSTATUS` |

Because `LocalProcessChildReaper.wait()` in `SwiftTerm` relies on `waitid(P_PID, pid, ..., WEXITED | WNOWAIT)` followed by `waitpid()`, it fails immediately with `ECHILD` on adopted processes.

---

## 3. Exit Monitoring & Signal Safety (`ProcessExitMonitor`)

Implemented in `Tecolot/HotReload/ProcessExitMonitor.swift`.

`ProcessExitMonitor` unifies owned and adopted processes behind two ownership modes:

- **`.owned`**: Used for processes forked directly by the current `Tecolot` instance. Monitors exit with `kqueue` `EVFILT_PROC` (`NOTE_EXIT`) and reaps using `waitid(P_PID, pid, &info, WEXITED | WNOWAIT)` + `waitpid()` under `reapLock`, preserving the exact PID-reuse protection of `LocalProcessChildReaper`.
- **`.adopted(startTime:)`**: Used for processes adopted over `SCM_RIGHTS`.
  - Registers `kqueue` `EVFILT_PROC` with **`NOTE_EXIT | NOTE_EXITSTATUS`** (`EV_ADD | EV_ENABLE | EV_ONESHOT`), alongside a self-pipe (`EVFILT_READ`) so `cancel()` wakes the waiter thread immediately without signaling or reaping.
  - On macOS, `EVFILT_PROC` with `NOTE_EXITSTATUS` works for **any process owned by the same UID** (even when reparented to `launchd`) and delivers the `wait(2)`-formatted exit status in `kevent.data`. Exit codes are decoded identically: `(status & 0x7f) == 0 ? (status >> 8) & 0xff : nil`.
  - **Already-exited race (`ESRCH`)**: If `shellPid` exited and was already reaped by `launchd` before registration, `kevent` reports `ESRCH` (either via `-1`/`errno == ESRCH` or an `EV_ERROR` event). The monitor immediately disables signaling and delivers `onExit(nil)`.
  - **PID-reuse protection (`ProcessStartTime`)**: Because `launchd` reaps adopted children immediately on exit, Process B cannot hold a zombie with `WNOWAIT`. To close the PID-reuse window, Process A records `(pbi_start_tvsec, pbi_start_tvusec)` via `proc_pidinfo(pid, PROC_PIDTBSDINFO, ...)` and includes it in the handoff metadata. Process B verifies `ProcessStartTime.current(for: pid) == expectedStart` both *immediately after* arming `EVFILT_PROC` and *under `reapLock` before every `kill()`*.
  - **PTY EOF vs `NOTE_EXIT` race**: On macOS, PTY master EOF and `NOTE_EXIT` arrive nearly simultaneously. `HotReloadableLocalProcess` lets `ProcessExitMonitor` deliver the authoritative `NOTE_EXITSTATUS` first, falling back to PTY EOF only after a 150 ms grace window if no exit event arrives.

---

## 4. Wire Protocol & Security (`FDTransferSocket`)

Implemented in `Tecolot/HotReload/FDTransferSocket.swift`.

### Transport & Authentication

- Process A creates a `0700` temporary directory `/tmp/tecolot-hr-<pid>-<12hex>` and binds `h.sock` (`chmod 0600`) inside it, keeping the socket path well below Darwin's 104-byte `sockaddr_un.sun_path` limit.
- Both sides set `SO_NOSIGPIPE` and `FD_CLOEXEC` on socket descriptors and enforce explicit `poll()` deadlines on every step.
- Both sides verify `getpeereid() == geteuid()`.
- Process A generates a 256-bit random hex token (`arc4random_buf`) passed to Process B via environment variables:
  - `TECOLOT_HOT_RELOAD_SOCKET`: Unix socket path
  - `TECOLOT_HOT_RELOAD_TOKEN`: hex authentication token
- Process A compares the token in constant time before sending any descriptors.

### Framing & `SCM_RIGHTS` Alignment

Messages are length-prefixed (`[4-byte big-endian UInt32][UTF-8 JSON]`). Because `SOCK_STREAM` is a byte stream, passing `SCM_RIGHTS` ancillary data requires unambiguous message boundaries so two control messages are never coalesced:

1. **Client -> Server `Hello`**: `{ protocolVersion: 1, token, receiverPID }`
2. **Server -> Client `Manifest`**: `{ protocolVersion: 1, sourcePID, paneCount }`
3. **Server -> Client `Pane` × `paneCount`**:
   - Framed JSON `HotReloadPaneEntry`: `{ paneID, shellPid, startTime, cols, rows }`
   - Followed by a single `sendmsg(SCM_RIGHTS)` carrying a 1-byte sentinel (`0xFD`) and **one** `Int32` file descriptor, aligned with Darwin's `__DARWIN_ALIGN32` (`CMSG_SPACE`/`CMSG_LEN`).
   - Receiver reads the exact JSON frame, then calls `recvmsg` with a 1-byte `iov`, verifies `sentinel == 0xFD` and `(msg_flags & MSG_CTRUNC) == 0`, extracts the FD, and sets `FD_CLOEXEC` via `fcntl(fd, F_SETFD, FD_CLOEXEC)`.
4. **Client -> Server `Ack`**: `{ ok, acceptedCount, error }`

---

## 5. Two-Phase Handoff Lifecycle

Implemented across `Tecolot/HotReload/HotReloadableLocalProcess.swift` and `Tecolot/HotReload/HotReloadCoordinator.swift`.

```mermaid
sequenceDiagram
    participant A as Old Tecolot (Process A)
    participant RS as RestoreStore (Disk)
    participant S as Unix Socket (0600)
    participant B as New Tecolot (Process B)
    participant K as Kernel / Shell PTY

    A->>K: 1. pauseForHandoff() (self-pipe stops reader thread, FD stays open)
    A->>RS: 2. saveForHotReload() (layout + normal scrollback)
    A->>S: 3. bind + listen
    A->>B: 4. Launch via NSWorkspace (createsNewApplicationInstance=true)
    B->>S: 5. connect + Hello(token)
    S-->>B: 6. Manifest + (PaneEntry + SCM_RIGHTS childfd) x N
    Note over B,K: Kernel refcount on PTY master is now 2
    B->>S: 7. Ack(ok=true, acceptedCount=N)
    A->>K: 8. commitHandoff() (close A's copy, no SIGTERM/SIGHUP)
    Note over B,K: Kernel refcount drops to 1; shell stays alive
    A->>A: 9. Terminate cleanly (bypass quit alert & saveForTermination)
    Note over K: XNU reparents shells to launchd (PID 1)
    B->>RS: 10. RestoreStore.restore()
    B->>K: 11. attachAdopted() + TIOCSWINSZ + SIGWINCH + kqueue NOTE_EXITSTATUS
```

### Failure & Rollback

If any step prior to receiving `Ack` fails (socket error, target launch failure, timeout, token mismatch, or `NACK`):

1. Process A closes and unlinks the temporary socket directory.
2. Process A calls `resumeAfterAbortedHandoff()` on every paused `AppTerminalView` (restarting the reader thread and `ProcessExitMonitor` on the still-open `childfd`) and returns any unclaimed dormant-tab FDs to `HotReloadInbox`.
3. Process A displays an alert explaining why the reload was aborted. Every running shell continues without interruption.

### Dormant Tabs & Chained Reloads

- Restored tabs that are not currently selected start dormant (`isUnshownRestoredPane`). Their transferred FDs remain open inside `HotReloadInbox.shared`, keeping their shells alive until the user opens those tabs.
- If a dormant pane is closed before ever attaching, `TerminalSessionController.terminate()` discards and closes its inbox FD.
- If Process B is hot-reloaded *again* (`B -> C`) before dormant tabs are opened, `HotReloadCoordinator` drains both active local panes and unclaimed `HotReloadInbox` descriptors and forwards all of them to Process C.

---

## 6. App Integration Details

- **`AppTerminalView` (`Tecolot/AppTerminalView.swift`)**: Subclasses `SwiftTerm.TerminalView` directly and owns `HotReloadableLocalProcess`, feeding PTY output via `feedSender.feed(byteArray:)` on the background reader thread. Exposes `pauseForHandoff()`, `resumeAfterAbortedHandoff()`, `commitHandoff()`, and `attachAdoptedProcess(...)`.
- **`RestoreStore` (`Tecolot/Restoration/RestoreStore.swift`)**:
  - `saveForHotReload()` persists all groups, windows, frames, split trees, and normal-buffer scrollback even when the user has disabled "Restore windows" for normal quits, without setting `isTerminating = true` (preserving rollback safety).
  - `restore()` runs whenever `isEnabled || HotReloadInbox.shared.hasReceivedHandoff`.
- **`PaneRestoration` & `TerminalSessionController`**:
  - When `HotReloadInbox.shared.contains(paneID: id)` is true, `beginLocalRestore` skips the filesystem directory check and omits the `"Session ended"` separator line.
  - `startShellIfReady()` claims the transferred FD via `HotReloadInbox.shared.take(paneID: id)`, replays saved scrollback, calls `terminal.attachAdoptedProcess(...)` (with `TIOCSWINSZ` + `SIGWINCH`), and skips `forkpty()`.
- **App Lifecycle (`Tecolot/TecolotApp.swift`)**:
  - `applicationDidFinishLaunching` invokes `HotReloadInbox.shared.receiveIfRequested()` before `RestoreStore.shared.restore()`.
  - `applicationShouldTerminate` returns `.terminateNow` immediately when `HotReloadCoordinator.shared.isExitingForHotReload` is true (bypassing the running-process confirmation dialog and `saveForTermination`).
  - `HotReloadCommands` exposes **Hot Reload Tecolot (Prototype)** and **Upgrade in Place from App…** in the application menu.

---

## 7. Proposed Upstream `SwiftTerm` APIs

Once the prototype is validated, moving the lifecycle hooks into `SwiftTerm.LocalProcess` (and `LocalProcessTerminalView`) lets `AppTerminalView` return to subclassing `LocalProcessTerminalView` directly while keeping `TerminalIOPipeline`:

1. `LocalProcess.pauseForHandoff() -> (childfd: Int32, shellPid: pid_t)?` — stops `TerminalIOPipeline` without closing `childfd` and cancels `childMonitor` without signaling or reaping.
2. `LocalProcess.resumeAfterAbortedHandoff()` — restarts `TerminalIOPipeline` and exit monitoring on rollback.
3. `LocalProcess.commitHandoff()` — closes `writeChannel` and `childfd` and marks `.handedOff` so `deinit` does not signal or reap.
4. `LocalProcess.attachAdopted(childfd: Int32, shellPid: pid_t, startTime: ProcessStartTime?)` — attaches `TerminalIOPipeline` + `DispatchIO` to an existing master FD and monitors exit with `kqueue` `EVFILT_PROC` (`NOTE_EXIT | NOTE_EXITSTATUS`) instead of `LocalProcessChildReaper.wait()`.

---

## 8. Path to Production

1. **Full `Terminal` state serialization**: Transfer both normal and alternate screen buffers, cursor state, active terminal mode flags (alternate screen, mouse reporting, bracketed paste, Kitty keyboard protocol, DECCKM, focus reporting), palette overrides, and Kitty graphics images alongside the `SCM_RIGHTS` FD so full-screen TUIs restore seamlessly without relying solely on `SIGWINCH`.
2. **Sparkle integration**: Hook `SPUUpdaterDelegate.updaterWillRelaunchApplication(_:)` (or a custom Sparkle relaunch driver) to invoke `HotReloadCoordinator` after Sparkle swaps `Tecolot.app` on disk.
3. **Remote SSH panes**: Continue reconnecting to remote `tecolot-sessiond`, or optionally transfer local `ssh` bridge FDs over `SCM_RIGHTS` to avoid re-authenticating SSH connections across upgrades.

---

## 9. How to Test

### 9.1 Automated Tests

Run the multi-process hot-reload test suite (`TecolotTests/HotReloadTests.swift`):

```sh
xcodebuild test \
  -project Tecolot.xcodeproj \
  -scheme Tecolot \
  -configuration Debug \
  -only-testing:TecolotTests/HotReloadTests \
  CODE_SIGNING_ALLOWED=NO
```

Run the related local-pane and restoration regression suites alongside it:

```sh
xcodebuild test \
  -project Tecolot.xcodeproj \
  -scheme Tecolot \
  -configuration Debug \
  -only-testing:TecolotTests/HotReloadTests \
  -only-testing:TecolotTests/RestoreStoreTests \
  -only-testing:TecolotTests/TerminalClearActionTests \
  -only-testing:TecolotTests/TerminalContextMenuTests \
  -only-testing:TecolotTests/TerminalFileDropTests \
  -only-testing:TecolotTests/TerminalPaneFocusTests \
  -only-testing:TecolotTests/TerminalClosePolicyTests \
  CODE_SIGNING_ALLOWED=NO
```

What `HotReloadTests` verifies:

- `SCM_RIGHTS` authentication (invalid token rejection, `getpeereid`, `FD_CLOEXEC`, post-close pipe I/O).
- **Real cross-process reparenting to `launchd` (PID 1)**: a separate sender process calls `pty.fork()`, transfers the master FD over `SCM_RIGHTS`, and exits (`os._exit(0)`). The test asserts `ppid == 1`, asserts `waitpid` returns `ECHILD`, exchanges live I/O with the reparented shell, and verifies `ProcessExitMonitor` recovers exact exit code `42`.
- `SIGTERM` termination of a reparented adopted shell reporting `exitCode == nil`.
- Two-phase `pauseForHandoff()` -> `resumeAfterAbortedHandoff()` rollback followed by `pauseForHandoff()` -> `SCM_RIGHTS` -> `commitHandoff()` without signaling on deinit.
- `HotReloadInbox` drain/restore/take/discard lifecycle.

### 9.2 Manual End-to-End Test: Same-Bundle Hot Reload

1. Build and launch `Tecolot.app` (from Xcode, or directly from `DerivedData` so Xcode's debugger does not intercept the app termination):
   ```sh
   open ~/Library/Developer/Xcode/DerivedData/Tecolot-*/Build/Products/Debug/Tecolot.app
   ```
2. Open a few **local** (non-persistent) panes across tabs and splits. For example:
   - **Pane 1 (shell state + PID check):**
     ```sh
     export HOT_RELOAD_CHECK=alive
     echo "shell=$$ ppid=$PPID"
     ```
   - **Pane 2 (active foreground job):** run `top` or `vim` (or `sleep 300`).
   - **Tab 2 (dormant tab check):** run `echo "tab2=$$"`, then switch back to Tab 1 so Tab 2 is not visible during reload.
3. Optional — stream hot-reload logs in another terminal (e.g., Terminal.app):
   ```sh
   log stream --info --predicate 'category == "HotReload"'
   ```
4. From the **Tecolot** menu bar, choose **Hot Reload Tecolot (Prototype)**.
5. Verify in the newly launched `Tecolot` window:
   - The old `Tecolot` process exited without showing the *"Quit and terminate running processes?"* dialog, and `pgrep -fl Tecolot` shows a **new** `Tecolot` PID.
   - In **Pane 1**: `echo "shell=$$ check=$HOT_RELOAD_CHECK"` prints the **same shell PID** and `check=alive`, with no *"Session ended"* separator line, and `ps -o pid,ppid,comm -p $$` shows **`PPID = 1`** (`launchd`).
   - In **Pane 2**: `top` / `vim` / `sleep 300` is still running and redrew via `SIGWINCH`.
   - Switch to **Tab 2**: `echo $$` prints the same `tab2` PID, proving dormant-tab FDs stayed open in `HotReloadInbox`.
   - **Exit code check (proves `kqueue` `NOTE_EXITSTATUS`):** in an adopted pane with *"When shell exits"* set to keep open (or observing close-if-cleanly), run `exit 42` and verify `[Process completed — exit 42]` is reported accurately.
   - **Chained reload check:** run **Hot Reload Tecolot (Prototype)** a *second* time and verify the already-adopted shells survive `B -> C` with the same PIDs.

### 9.3 Manual End-to-End Test: Upgrade in Place from Another `.app` Bundle

1. Make a second copy of the app bundle (or build a modified version with a visible change such as an updated menu/title string):
   ```sh
   cp -R ~/Library/Developer/Xcode/DerivedData/Tecolot-*/Build/Products/Debug/Tecolot.app /tmp/Tecolot-v2.app
   ```
2. With live local panes running in the original `Tecolot.app`, choose **Tecolot -> Upgrade in Place from App…** and select `/tmp/Tecolot-v2.app`.
3. Verify the running process path (`ps -o pid,comm -p $(pgrep -x Tecolot)`) now points to `/tmp/Tecolot-v2.app` while all local shells remain alive with their original PIDs.

### 9.4 Manual Test: Rollback on Failed Handoff

1. Choose **Tecolot -> Upgrade in Place from App…** and select an `.app` bundle that does not speak the Tecolot hot-reload protocol (e.g., `/System/Applications/Calculator.app`).
2. After the 15-second handoff timeout expires, verify the *"Hot Reload Aborted"* alert appears and every local pane in the original `Tecolot` resumes accepting input and displaying output without losing any running process.
