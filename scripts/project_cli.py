#!/usr/bin/env python3
"""project_cli.py: the read/write interface to this workspace's project identity.

Fully local: this touches only files under this workspace's data/ directory. This is the
one thing missing from the original three CLIs: name, tagline and pitch drive the homepage
but had no command of their own, so changing them meant re-running init_workspace.py --force
or hand-editing the JSON, both of which this tool otherwise tells you not to do.

  project_cli.py show
  project_cli.py update [--name "..."] [--tagline "..."] [--pitch "..."]
  project_cli.py render          # regenerate index.html's embedded data block from project.json

Every mutating command re-renders index.html automatically. `render` alone is only needed if
project.json was hand-edited.
"""
import argparse
import contextlib
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA_PATH = os.path.join(ROOT, "data", "project.json")
HTML_PATH = os.path.join(ROOT, "index.html")
LOCK_PATH = DATA_PATH + ".lock"


@contextlib.contextmanager
def locked(timeout=10.0):
    """Guards the load/modify/save cycle so two CLI calls running at the same time can't
    each read the same starting state and silently overwrite each other's change. Uses a
    plain lock file with exclusive create (os.O_EXCL), which is atomic on every platform
    Python runs on, so this needs no extra dependency and no platform-specific locking API."""
    deadline = time.time() + timeout
    while True:
        try:
            fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
            break
        except FileExistsError:
            if time.time() > deadline:
                try:
                    if time.time() - os.path.getmtime(LOCK_PATH) > timeout:
                        os.remove(LOCK_PATH)
                        continue
                except OSError:
                    pass
                sys.exit(f"could not acquire {LOCK_PATH} within {timeout}s. "
                         f"Is another project_cli.py call running?")
            time.sleep(0.05)
    try:
        yield
    finally:
        try:
            os.remove(LOCK_PATH)
        except OSError:
            pass


def load():
    with open(DATA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def save(project):
    tmp_path = DATA_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(project, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp_path, DATA_PATH)


def cmd_show(project, _args):
    print(json.dumps(project, indent=2, ensure_ascii=False))


def cmd_update(project, args):
    if args.name is not None:
        project["name"] = args.name
    if args.tagline is not None:
        project["tagline"] = args.tagline
    if args.pitch is not None:
        project["pitch"] = args.pitch
    save(project)
    render(project)
    print("updated project")


def render(project):
    """Regenerate ONLY the embedded <script id="project-data"> JSON block in index.html.
    Never touches the surrounding page chrome."""
    if not os.path.exists(HTML_PATH):
        print(f"WARN: {HTML_PATH} not found, skipping render", file=sys.stderr)
        return
    html = open(HTML_PATH, encoding="utf-8").read()
    # json.dumps() doesn't escape "<", so a name/tagline/pitch containing "</script>" would
    # otherwise close the data block early and corrupt the page.
    payload = json.dumps(project, indent=2, ensure_ascii=False).replace("<", "\\u003c")
    pattern = re.compile(
        r'(<script id="project-data" type="application/json">)(.*?)(</script>)',
        re.S,
    )
    new_html, n = pattern.subn(lambda m: m.group(1) + "\n" + payload + "\n" + m.group(3), html, count=1)
    if n == 0:
        sys.exit(f'no <script id="project-data"> block found in {HTML_PATH}, cannot render')
    # Same tmp-then-os.replace() dance save() uses: the page is what a browser has open,
    # and a crash (or a reload) mid-write would otherwise leave a truncated, unusable file.
    tmp_html = HTML_PATH + ".tmp"
    with open(tmp_html, "w", encoding="utf-8") as fh:
        fh.write(new_html)
    os.replace(tmp_html, HTML_PATH)


def cmd_render(project, _args):
    render(project)
    print("rendered index.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("show")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("update")
    p.add_argument("--name")
    p.add_argument("--tagline")
    p.add_argument("--pitch")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("render")
    p.set_defaults(fn=cmd_render)

    args = ap.parse_args()
    with locked():
        project = load()
        args.fn(project, args)


if __name__ == "__main__":
    main()
