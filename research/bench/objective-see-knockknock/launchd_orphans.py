"""Counts launchd plists in the dirs KnockKnock scans (ItemEnumerator.m:21, non-root view)
whose Program / ProgramArguments[0] does not exist. KnockKnock's LaunchItems.m:176 drops such
items because Results/File.m:59-75 returns nil for a missing path. Prints counts only."""
import os, plistlib, shutil

DIRS = ["/Library/LaunchDaemons", "/Library/LaunchAgents", os.path.expanduser("~/Library/LaunchAgents")]
for d in DIRS:
    total = orphan = unreadable = 0
    try:
        names = [n for n in os.listdir(d) if n.endswith(".plist")]
    except OSError as e:
        print(f"{d}: listdir failed errno={e.errno}")
        continue
    for n in names:
        total += 1
        try:
            with open(os.path.join(d, n), "rb") as f:
                p = {k.lower(): v for k, v in plistlib.load(f).items()}
        except Exception:
            unreadable += 1
            continue
        prog = p.get("program")
        if prog is None:
            args = p.get("programarguments")
            prog = args[0] if isinstance(args, list) and args else args
        if not isinstance(prog, str):
            continue
        if not prog.startswith("/"):
            prog = shutil.which(prog) or prog  # File.m:63 falls back to which()
        if not os.path.exists(prog):
            orphan += 1
    label = d.replace(os.path.expanduser("~"), "~")
    print(f"{label}: plists={total} program-missing={orphan} unparseable={unreadable}")
