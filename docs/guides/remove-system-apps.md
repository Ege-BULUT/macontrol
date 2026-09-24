# Remove macOS's own apps yourself

**Strongly not recommended.** This is the text of macontrol's expert guide, the sheet behind "Expert: remove system
apps yourself…" in the panel of an app that is part of macOS (Chess, Stocks, News, Tips…). macontrol shows the steps
and runs none of them. It cannot remove these apps itself: they live on a sealed, read-only system volume, and no
app can change that volume while System Integrity Protection is on.

All of macOS's own apps together use about 0.73 GB (macOS 26.6), and a macOS update puts them back. Removing them
gives back almost no space. Apple's App Store apps (GarageBand, iMovie, Pages, Numbers, Keynote, Xcode) are a
different matter: macontrol's Debloat section removes those without any of this.

Each step below is tagged:

- *(verified)*: run on a Mac with macOS 26.6 (Apple silicon, SIP on) while writing this guide. Only commands that
  read were run.
- *(unverified)*: follows Apple's documentation, the man pages on macOS 26.6 (`csrutil`, `bless`) and reports by
  others, but has not been run end to end. It will be tested in macOS 14, 15 and 26 virtual machines before macontrol
  offers to do any of it (DESIGN-debloat section 5.4).

## Before you start

- This lowers your Mac's security. With protection off, iPhone and iPad apps and Apple Pay may stop working (reported by others, unverified).
- You must turn off FileVault first. Your files are not encrypted until you turn it back on, which takes hours.
- The apps stay removed only while these protections stay off. Turning them back on brings the apps back.
- macOS updates bring these apps back, and may then install as a full download.
- Almost no space comes back: the previous sealed snapshot keeps the files (expected, not yet tested).
- A mistake can leave your Mac unable to start until you reinstall macOS from Recovery.
- **Make a Time Machine backup first.** Time Machine does not back up the system volume (expected, not yet tested); the way back is the previous sealed snapshot or reinstalling macOS, which keeps your files.

In the app, the steps appear only after you tick **I have a backup and I accept these risks**.

## What macontrol fills in

The sheet writes every command for your Mac, with literal absolute paths in single quotes and no shell variables, so
a command can't land on a different folder than the one it names. The examples below use Chess, the home folder
`/Users/you` and the system volume `/dev/disk3s3`. macontrol reads the system volume from the startup disk
(`/dev/disk3s3s1` on the Mac this was written on) and drops the snapshot's last `s1`. Apps outside
`/System/Applications` and its `Utilities` folder get no command, and neither does a name or home folder that holds a
`$` or a line break. System Settings and Terminal get no command either: "The undo steps need this app." When no app
is left to remove, the sheet shows no steps and no undo steps.

If System Integrity Protection and Authenticated Root are already off, the sheet says so:

> System Integrity Protection and Authenticated Root are off on this Mac. macontrol doesn't remove system apps itself until this procedure and its undo have been tested on macOS 14, 15 and 26. Until then, these are steps you run yourself.

It then leaves out steps 1 to 4 below and numbers its own steps from 1: first this FileVault check, then steps 5 to 7
(so "Mount the system volume" is step 2 there).

### Check that FileVault is off *(verified)*

Open Terminal. This command should say "FileVault is Off." It only reads, and needs no password. If FileVault is on, stop here and turn it off first: System Settings > Privacy & Security > FileVault > Turn Off.

```sh
fdesetup status
```

Verified: on macOS 26.6 it runs without a password and prints `FileVault is Off.` on a Mac with FileVault off.

## Steps

### 1. Turn off FileVault *(unverified)*

System Settings > Privacy & Security > FileVault > Turn Off. Wait until it has finished; this can take hours.

The signed system volume can't be turned off while FileVault is on (Apple Platform Security, "Signed system volume
security").

### 2. Start up in macOS Recovery *(unverified)*

Mac with Apple silicon: shut down, then press and hold the power button until "Loading startup options" appears, and choose Options. Intel Mac: restart and hold Command-R.

### 3. Turn off both protections in Recovery *(unverified)*

In Recovery, choose Utilities > Terminal and run these two commands. Then restart from the Apple menu.

```sh
csrutil disable
csrutil authenticated-root disable
```

`csrutil` on macOS 26.6 lists `authenticated-root disable` as "Only available in Recovery OS".

### 4. Check that both are off *(unverified)*

Back in macOS, open Terminal. Both commands should say disabled. These only read, and need no password. Then open this guide in macontrol again and copy the next commands from there: they name the disk your Mac started up from, which can change after a restart.

```sh
csrutil status
csrutil authenticated-root status
```

Both run without a password on macOS 26.6 (checked), but their output with the protections off has not been seen
yet, so the step is unverified.

### 5. Mount the system volume *(unverified)*

Makes an empty folder in your home folder and mounts this Mac's system volume there, the startup disk without its sealed snapshot. The second command asks for your password.

```sh
mkdir '/Users/you/sysmount'
sudo mount -o nobrowse -t apfs '/dev/disk3s3' '/Users/you/sysmount'
```

### 6. Delete the apps *(unverified)*

Each command deletes one app from the mounted system volume.

```sh
sudo rm -rf '/Users/you/sysmount/System/Applications/Chess.app'
```

An app in the Utilities folder ends in `System/Applications/Utilities/<name>.app'` instead.

### 7. Make the changed volume the one that starts up *(unverified)*

This creates a new system snapshot and starts up from it. Then restart your Mac.

```sh
sudo bless --mount '/Users/you/sysmount' --bootefi --create-snapshot
```

`man bless` on macOS 26.6: `--create-snapshot` creates an APFS root snapshot of the target system volume and sets it
as the root snapshot for the next boot.

## To undo

### 1. Go back to the sealed snapshot *(unverified)*

Starts up from the previous sealed snapshot, which still has the apps. Then restart your Mac.

```sh
sudo bless --mount '/' --bootefi --last-sealed-snapshot
```

`man bless` on macOS 26.6: `--last-sealed-snapshot` "Reverts back to using the previously signed APFS root snapshot
reenabling Authenticated Root Volume". The exact form of this command has not been run yet.

### 2. Turn both protections back on in Recovery *(unverified)*

Start up in macOS Recovery again, choose Utilities > Terminal, run these two commands, then restart.

```sh
csrutil authenticated-root enable
csrutil enable
```

### 3. Turn FileVault back on *(unverified)*

System Settings > Privacy & Security > FileVault > Turn On.

### 4. If your Mac doesn't start up *(unverified)*

Start up in macOS Recovery and choose Reinstall macOS. It keeps your files.

## Sources

- `docs/research/feasibility-apple-apps.md`: facts D1-D5 (how macontrol detects the state), S1-S15 (what is sealed and
  what the procedure rests on), and the original guide text.
- `docs/DESIGN-debloat.md` sections 5.1-5.5: what macontrol shows, and what this Mac cannot verify.
