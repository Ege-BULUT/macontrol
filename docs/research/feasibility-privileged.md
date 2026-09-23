# Feasibility: privileged deletion without a paid developer account

Task T-0068 (M7, debloat). Researcher: feas-privileged, 2026-09-23.
Question from M-0045.4: an ad-hoc-signed, non-notarized, open-source macontrol must delete root-owned
leftovers and remove Apple's App Store apps (GarageBand, iMovie, iWork) with their content, "like PureMac
does", while keeping every Safety rule (no shell with paths, identity checks, protected paths). How does an
app with **no paid Apple Developer account** run a root-level delete safely?

This machine: macOS 26.6 (build 25G72), SIP enabled, Authenticated Root enabled, one code-signing identity
("Apple Development", **no "Developer ID Application"**), so it cannot notarize (verified-locally,
`security find-identity -v -p codesigning`; matches D9). SDK: MacOSX26.5. All probes ran non-root in the
scratchpad; nothing on the system was modified.

Evidence tags: **verified-locally** (a probe I ran on this Mac), **sourced** (Apple doc / man page / Apple
open-source / DTS forum with a URL), **unverified** (could not run to completion here — an escalation needs
an admin password, which the run cannot request).

## TL;DR recommendation

Use **mechanism (a): AppleScript `do shell script … with administrator privileges` (via `NSAppleScript`)
launching a bundled, compiled macontrol helper that receives the request through a 0600 file and never sees a
path on the shell command line.** It is the only option that (1) works with ad-hoc signing and no paid
account, (2) is a supported, non-deprecated API callable cleanly from Swift, and (3) is one-shot and
user-authorized, which sidesteps the ad-hoc caller-validation problem that kills the persistent-daemon route.
Keep the helper's argv/stdin protocol launcher-independent so `AuthorizationExecuteWithPrivileges` (mechanism
c) can be dropped in as a shell-free fallback with a ~10-line change and no protocol change.

## Facts table

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 1 | `SMJobBless` deprecated since macOS 13 ("Please use SMAppService instead"); `SMJobSubmit`/`SMJobRemove` deprecated since 10.10; `AuthorizationExecuteWithPrivileges` deprecated since 10.7. | verified-locally | SDK `ServiceManagement.h:81,110,143,260`, `Security/Authorization.h:431` |
| 2 | `SMAppService.daemon(plistName:)` is macOS 13+. **"Apps that contain LaunchDaemons must be notarized."** `register()` returns `kSMErrorInvalidSignature` if "the app bundle is not properly code signed" and `kSMErrorLaunchDeniedByUser` until an admin approves it in System Settings > Login Items. | verified-locally (SDK) + sourced | SDK `SMAppService.h:49,55,131,166,168` |
| 3 | Notarization requires a Developer ID cert (not ad-hoc/Apple-Development), Hardened Runtime, secure timestamp; the Apple Developer Program is 99 USD/yr and notarization is member-only. | sourced | developer.apple.com/documentation/security/notarizing-macos-software-before-distribution ; developer.apple.com/programs/whats-included/ ; matches D5, D8 |
| 4 | Apple DTS (Quinn "The Eskimo!"): with ad-hoc signing ("Sign to Run Locally"), an `SMAppService` daemon fails — loses background-execution rights, and in Sequoia+ shows "Item from unidentified developer" and does not run. Both app and embedded helper must be signed with the **same Apple-issued identity**. | sourced | developer.apple.com/forums/thread/799910 ; developer.apple.com/forums/thread/757463 |
| 5 | ⇒ **SMAppService.daemon / SMJobBless are not usable without a paid account** (notarization gate #2 + ad-hoc failure #4). | verified-locally (reasoning from #2,#4) + sourced | — |
| 6 | An ad-hoc binary has **no Team Identifier**; its designated requirement is only its **cdhash**. `identifier "…"` is trivially satisfied by any ad-hoc binary that declares that identifier. | verified-locally | signed two ad-hoc binaries `genuine`/`impostor` with the same `-i dev.macontrol.Macontrol`; both pass `codesign --verify -R='identifier "dev.macontrol.Macontrol"'`; each has a distinct `Signature=adhoc`, `TeamIdentifier=not set`, different CDHash |
| 7 | Pearcleaner's caller check (`codeSigningCertificates` equality, `kSecCodeInfoCertificates`) is **useless for ad-hoc code**: the certificates key is absent, so two *different* ad-hoc binaries compare **equal**. | verified-locally | `certprobe genuine impostor` → "certificate arrays equal: true"; vs `/usr/bin/true` → false |
| 8 | Pinning `cdhash H"…"` in a code requirement does reject a different or tampered binary, and survives a plain copy. | verified-locally | `codesign --verify --strict -R='cdhash H"…"'`: passes on a copy, fails on `impostor` and on a byte-appended+re-signed `tampered` ("failed strict validation") |
| 9 | `AuthorizationExecuteWithPrivileges` (+ `…ExternalForm`, `…Internal`, `AuthorizationCopyPrivilegedReference`) are **still present** in Security.framework on 26.6. | verified-locally | `dlsym` on Security.framework → all four "present" |
| 10 | AEWP is **unavailable in Swift** and must be reached via `dlopen`/`dlsym`+`unsafeBitCast` (as AlinFoundation/Pearcleaner do). | verified-locally | `swiftc` on `let f = AuthorizationExecuteWithPrivileges` → "unavailable in macOS: APIs deprecated as of macOS 10.9 and earlier are unavailable in Swift" |
| 11 | AEWP does **not** use a shell: it forks and `execv`s `/usr/libexec/security_authtrampoline`, which (via a root XPC daemon `com.apple.security.authtrampoline`) `posix_spawn`s **your tool with argv directly**. It uses the `system.privilege.admin` right and logs a deprecation warning each call ("functionality will be removed soon"). | sourced + verified-locally | Apple OSS `Security` `trampolineClient.cpp`/`trampolineServer.cpp` (rev Security-61901.0.87, main); `/System/Library/LaunchDaemons/com.apple.security.authtrampoline.plist` (verified-locally), daemon signed `macOS Software Signing`, imports `_posix_spawn`/`_AuthorizationCopyRights` (verified-locally `nm`) |
| 12 | `do shell script … with administrator privileges` runs **`/bin/sh -c <string>` as root** (real+effective uid 0), one auth dialog, and **does not re-prompt for 5 minutes** for the *same* script; a different/modified script re-prompts. Non-zero exit → AppleScript error whose number is the exit status. Use **`quoted form of`** for every variable. | sourced | TN2065 (developer.apple.com/library/archive/technotes/tn2065); StandardAdditions.sdef `do shell script` (verified-locally). `system.privilege.admin` rule has `timeout=300`, `authenticate-user=true`, `group=admin` (verified-locally `security authorizationdb read`) |
| 13 | `NSAppleScript` executed with a real Apple event (typed argv list) passes hostile filenames through `do shell script` + `quoted form of` **byte-exact**: `$(…)`, backticks, `;`, newline, `'`, `"`, `\`, tab, `*`, combining marks, emoji all round-tripped and **nothing executed**. The launched helper was a bundled **ad-hoc-signed** binary that read its argv unchanged. | verified-locally (non-root) | `quoteprobe.swift`: "round-trip exact: 21/21"; helper lived under a dir named `…$(touch PWNED0)…`; no `PWNED*` file appeared |
| 14 | The `/bin/sh` that `do shell script` spawns **inherits the caller's environment**, and a poisoned environment defeats even perfect `quoted form of` quoting: `PS4` + `SHELLOPTS=xtrace` and `BASH_ENV` run attacker code inside `/bin/sh -c` and inside `osascript`'s `do shell script`. | verified-locally (non-root) | set `SHELLOPTS=xtrace PS4='$(touch …)'` and `BASH_ENV=…` around `/bin/sh -c` and `osascript` → the injected files were created |
| 15 | Apple DTS ranking of escalation options (updated 2025-03-24): never setuid-root; `sudo`/`authopen`/`osascript` are "**not appropriate to use as API**"; for **one-shot** privileges in an ad-hoc/limited-audience tool use **`AuthorizationExecuteWithPrivileges` or AppleScript**; `SMAppService` is for **ongoing** privileges; **never run GUI code as root**. | sourced | developer.apple.com/forums/thread/708765 |
| 16 | Fd-relative, symlink-proof primitives exist and are what the helper must use as root: `open(…O_NOFOLLOW_ANY / O_RESOLVE_BENEATH)`, `openat`, `unlinkat(…AT_SYMLINK_NOFOLLOW_ANY / AT_RESOLVE_BENEATH / AT_UNIQUE)`, `renameatx_np(…RENAME_NOFOLLOW_ANY / RENAME_EXCL)`, `removefileat(fd, …REMOVEFILE_RECURSIVE)`. `removefile(3)` warns it is "pathname-based … potential race conditions that may add risk when run with privileges" and "operates on symbolic links, rather than the target". | verified-locally (SDK) + sourced | SDK `sys/fcntl.h:158,184,185`, `sys/stdio.h:39`, `removefile.h:22-71`; `man 2 open`, `man 2 unlink`, `man 2 rename`, `man 3 removefile` |
| 17 | The sealed system volume is `read-only` + `Sealed: Yes`; `/System/Applications/*` and Safari are `root:wheel restricted`. Root cannot delete them without disabling SIP + the seal. Apple's App Store apps and root-owned `/Library/…` items are ordinary `root:wheel`, not `restricted`, and are removable by root. | verified-locally | `mount`, `diskutil info /`, `ls -lO /System/Applications/Chess.app`, `/Applications/Safari.app`; matches A8 / ARCHITECTURE §7 |
| 18 | `sudo` credential caching is 5 min by default (`timestamp_timeout`), and for a non-tty shell child the timestamp is keyed by parent-process (`timestamp_type ppid`), so a helper invocation authenticates separately. macOS `sudo` auth goes through PAM (`pam_opendirectory`, optional `pam_smartcard`); `/etc/sudoers` is not app-controlled. | verified-locally | `man sudoers`, `/etc/pam.d/sudo`, `/etc/sudoers` perms |

## The four mechanisms compared

| | (a) AppleScript `do shell script … with administrator privileges` → bundled argv helper | (b) SMAppService.daemon / SMJobBless | (c) AuthorizationExecuteWithPrivileges | (d) sudo + SUDO_ASKPASS |
|---|---|---|---|---|
| Works with ad-hoc, no paid account? | **Yes** (#13, one-shot, user-authorized) | **No** — needs notarization (#2) and ad-hoc daemons fail to launch (#4,#5) | **Yes** (#9) | Yes, but see below |
| Deprecated? | **No** (TN2065 current, DTS-blessed for native code #12,#15) | SMJobBless yes (13.0); SMAppService current | **Yes** since 10.7; "removed soon" warning; Swift-unavailable (#1,#10,#11) | n/a (but "not appropriate as API" #15) |
| Password prompt frequency | 1 dialog, cached 5 min for the *same* script (#12) | 1 admin approval in System Settings, then persistent (#2) | 1 dialog, `system.privilege.admin` 5-min grace (#12,#11) | 1 askpass dialog, 5-min grace, per-ppid (#18) |
| Shell in the path? | Yes — `/bin/sh -c` (must quote + scrub env #12,#14) | No (XPC) | **No** — trampoline `posix_spawn`s the tool with argv (#11) | Yes — you assemble a sudo argv and an askpass program |
| Caller validation | N/A — user authorizes this one call; no persistent service to abuse | Needs `setCodeSigningRequirement` / `xpc_connection_set_peer_code_signing_requirement`, but ad-hoc has only cdhash (#6,#7,#8) | N/A — user authorizes this one call | N/A |
| TOCTOU exposure | Helper acts as root on paths ⇒ must re-resolve fd-relative + re-check identity (#16) | Same (daemon acts on paths) | Same | Same, plus you shell out |
| Auditability | Helper journals each path; shell runs only our one binary; Apple event args visible | launchd/BTM record; persistent attack surface | os_log deprecation line each call; argv visible | sudo logs to system log; behaviour depends on sudoers |
| Verdict | **Recommended** | Rejected (no paid account) | Fallback (shell-free, but deprecated + Swift-unavailable) | Rejected (DTS: not API; app would hold the password; sudoers not ours) |

## Recommended mechanism and protocol

**Launcher:** `NSAppleScript` running, with a typed Apple-event argv list (no string interpolation in the
AppleScript source itself):

```applescript
on run argv
    do shell script (quoted form of (item 1 of argv)) & " " & (quoted form of (item 2 of argv)) ¬
        with administrator privileges
end run
```

`item 1` = absolute path to the bundled helper (`…/Macontrol.app/Contents/Library/macontrol-priv`),
`item 2` = absolute path to a per-call **request file**. **No user path ever reaches the shell command line**
— only these two macontrol-controlled paths do, each wrapped by `quoted form of` (#13). The paths to delete
travel inside the request file as data (PureMac's NUL-staging idea #F-0012, done right).

**Request file (the app writes it, the helper is the authority):**
1. App `mkdtemp`s a 0700 dir it owns (e.g. under `~/Library/Application Support/Macontrol/priv/`), writes
   `request.bin` mode **0600**, then invokes the launcher. Format:
   - line `MACONTROL-PRIV/1`
   - `op trash` or `op remove` (permanent; "hardcore mode" only)
   - a fresh 256-bit hex `nonce`
   - one record per item: `dev inode allocated <len> <path-bytes>` (identity from the scan, so the helper can
     confirm the object is the one the user reviewed).
2. Helper opens the request file with `O_NOFOLLOW|O_CLOEXEC`, `fstat`s it: refuse unless it is a regular
   file, mode `0600`, owned by the invoking user or root, size bounded. (The 0600-in-a-0700-dir + one-time
   nonce is the anti-replay/anti-race guard, replacing any caller-code check, which #6–#8 show is worthless
   for ad-hoc.)

**Helper validation, per item, as root, before any mutation** — the app is **not trusted**; the helper
re-runs the exact Safety policy (F-0002 lesson):
1. Canonicalize: `F_GETPATH` on the parent opened `O_DIRECTORY|O_NOFOLLOW_ANY`, plus the on-disk leaf name
   (mirrors `Sources/Safety/ProtectedPaths.canonicalPath`).
2. Apply the **same `ProtectedPaths` policy compiled into the helper** — one shared Swift source file built
   into both the app and the helper; the helper's copy is the one that decides. Refuse protected roots /
   never-touch areas / `SF_RESTRICTED` / read-only or sealed volume / cross-device mount points.
3. Re-`lstat` and compare `(dev, inode)` to the request's expected identity; refuse on mismatch
   (`identityChanged`) — this closes the root TOCTOU window (#16; PureMac F-0012 skips this recheck).
4. Act **fd-relative, no-follow**: open the parent `O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC`; for `trash`,
   `renameatx_np` into the volume's `.Trashes/<uid>` with `RENAME_NOFOLLOW_ANY` (or `RENAME_EXCL` on
   collision); for `remove`, `removefileat(parentfd, name, REMOVEFILE_RECURSIVE)` — never `removefile()` on a
   full path (#16 race warning), never a shell `rm`.
5. Journal each outcome to the 0600 JSONL trash-journal (same schema as `TrashJournal`), `chown` back to the
   user, before printing the result line.

**Helper environment:** at entry, ignore the inherited environment (do not honour `PATH`, `BASH_ENV`,
`SHELLOPTS`, `PS4`, dyld vars). The parent shell is unavoidable (#12); env scrubbing + never re-invoking a
shell removes the #14 attack surface.

**Response / exit codes** (`do shell script` returns stdout; a non-zero exit throws with the number, #12):
- stdout: one line per item, `INDEX STATUS` where STATUS ∈ `ok | refused-protected | identity-changed |
  missing | error:<errno>`.
- exit: `0` (`EX_OK`) all applied; `65` (`EX_DATAERR`) malformed request; `77` (`EX_NOPERM`) request-file
  owner/mode/nonce check failed; `71` (`EX_OSERR`) one or more items failed (app reads the per-line detail).
  (`sysexits.h`, verified-locally.)

**Scope guard (F-0014):** the privileged path takes an `interactive` flag and asserts it is true; it is never
reachable from a timer / scheduled clean.

## Defects in PureMac / Pearcleaner this design avoids

- **F-0002 (Pearcleaner):** a general `runCommand(String)` → `/bin/bash -c` root service, paths built into a
  double-quoted string, PID-based caller check. We ship **no command-string API and no persistent service**:
  argv+request-file only, one-shot user-authorized, so there is nothing for another process to call and no
  caller-identity to forge (and #6–#8 show ad-hoc caller checks are worthless anyway).
- **F-0012 (PureMac):** root pass is `xargs -0 /bin/rm -rf` with **no per-path `(dev,inode)` recheck** between
  allow-list validation and the unlink, permanent, no journal/quarantine. We recheck identity on the opened
  fd immediately before each delete, act fd-relative no-follow, journal every path, and **default to Trash**;
  permanent delete is the opt-in "hardcore mode" only. (We keep PureMac's good ideas: NUL-separated staging,
  re-validation, and capturing the inode before delete to tell a daemon-recreated log from a survivor.)
- **F-0014 (PureMac):** unattended/scheduled admin escalation + permanent delete. Our privileged path asserts
  `interactive == true` and is never driven by a timer.

## Open questions / risks

1. **Notarization is a separate wall.** Even with a working privileged delete, an unnotarized app needs
   System Settings → "Open Anyway" + admin on first launch on macOS 15+ (D6/D7, sourced). Privilege
   escalation works regardless; distribution UX is the price of no paid account. (unverified here — no
   notarizable build possible on this Mac, #D9.)
2. **5-minute credential caching (#12) means a second batch within 5 min won't re-prompt.** For permanent
   ("hardcore") deletes we may want to force re-auth per batch; the `system.privilege.admin` timeout is
   system policy and not app-settable. A custom auth right (as Sparkle defines one, sourced) could carry a
   better-worded prompt but not shorten the grace. Decide whether the in-app "hardcore" modal confirmation
   (M-0045.5) is sufficient. (unverified.)
3. **The escalated run itself was not executed here** — the run cannot supply an admin password. #13/#14 are
   verified at uid 501; that the same quoting/argv passing holds *as root* rests on TN2065 + the AEWP
   trampoline source (#11,#12, sourced), and needs a manual check on a real password entry before shipping.
4. **`removefileat` recursion vs. our own walker.** `removefileat(REMOVEFILE_RECURSIVE)` is descent inside
   libc and not itself fully symlink-hardened per element; for a hostile tree the safest is our own
   fd-relative recursive unlink (openat/unlinkat with `AT_SYMLINK_NOFOLLOW`), matching ScanEngine's walk.
   Bench which is acceptable for large `/Library/Application Support/<vendor>` trees. (unverified.)
5. **Helper location & upgrade.** Bundled at `Contents/Library/macontrol-priv`, ad-hoc signed; no persistence
   to keep in sync (unlike a daemon), so no BTM desync problems. Confirm the path survives the
   `scripts/bundle-app.sh` layout. (unverified.)
