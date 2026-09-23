#!/usr/bin/env python3
"""Probe: QDirStat cleanup placeholder expansion re-expands %d/%n inside an
already-substituted path, which breaks its single-quote escaping.

Behavioural model (not a copy) of shundhammer/qdirstat@88a577f src/Cleanup.cpp:
  expandVariables() :176-196  -> three sequential QString::replace calls, %p, then %n, then %d
  quoted()          :199-202  -> "'" + s + "'"
  escaped()         :205-225  -> s.replace("'", "'\\''")
  runCommand()      :265-294  -> QProcess(shell, ["-c", expanded]), cwd = itemDir(item)
  defaultShell()    :336-372  -> $SHELL first, then /bin/bash, /bin/sh
QString::replace(before, after) replaces every non-overlapping match of the
*current* string and does not rescan inserted text: Python str.replace has the
same semantics.

Safety: `rm` is shadowed by a shell function that only prints its argv, and
everything runs inside a fresh temp dir. The only side effect is the marker
file created by the injection case, inside that temp dir.
"""
import os, subprocess, tempfile


def q(s):  # quoted(escaped(s))
    return "'" + s.replace("'", "'\\''") + "'"


def expand(cmd, path, is_dir):
    name = os.path.basename(path)
    dir_name = path if is_dir else os.path.dirname(path)
    cmd = cmd.replace("%p", q(path))
    cmd = cmd.replace("%n", q(name))
    if dir_name:
        cmd = cmd.replace("%d", q(dir_name))
    return cmd


SHADOW = 'rm(){ for a in "$@"; do printf "  argv: <%s>\\n" "$a"; done; }; tar(){ :; }; '

CASES = [
    # (label, template (from StdCleanup.cpp), relative path under tmp, is_dir)
    ("control: no placeholder in name", "rm -rf %p", "My Files/report.txt", False),
    ("'%d' in file name, space in dir", "rm -rf %p", "My Files/Sales 100%done.xlsx", False),
    ("'%d' in name, '&' in dir name", "rm -rf %p", "Tom & Jerry/frame%d.png", False),
    ("'%d' in name, $(...) in dir name", "rm -rf %p", "x$(touch PWNED)/frame%d.png", False),
]

with tempfile.TemporaryDirectory() as tmp:
    for label, tmpl, rel, is_dir in CASES:
        path = os.path.join(tmp, rel)
        os.makedirs(path if is_dir else os.path.dirname(path), exist_ok=True)
        if not is_dir:
            open(path, "w").close()
        cmd = expand(tmpl, path, is_dir)
        cwd = path if is_dir else os.path.dirname(path)
        print(f"== {label}\n  template: {tmpl}\n  target:   {rel}\n  expanded: {cmd.replace(tmp, '$TMP')}")
        for sh in ("/bin/zsh", "/bin/bash"):
            r = subprocess.run([sh, "-c", SHADOW + cmd], cwd=cwd, capture_output=True, text=True, timeout=10)
            out = (r.stdout + r.stderr).replace(tmp, "$TMP").rstrip()
            print(f"  [{sh}] exit={r.returncode}\n{out}")
        pwned = [os.path.relpath(os.path.join(d, f), tmp) for d, _, fs in os.walk(tmp) for f in fs if f == "PWNED"]
        print(f"  marker files: {pwned}\n")
