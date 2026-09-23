#!/usr/bin/env python3
"""memory_cli.py: the read/write interface to this project's agent-journal system.

Fully local: this touches only files under this workspace's data/ directory. Never call anything
network-facing from here. Each journal is a log an agent (or a human) owns and names; write a
new one for a distinct thread of work rather than piling everything into one entry.

  memory_cli.py list
  memory_cli.py show M-0001
  memory_cli.py create --name "..." --owner "..." [--contributor "..."]... [--content-file PATH]
  memory_cli.py append M-0001 --content-file PATH [--author "..."]
      # adds a timestamped section to the entry's content, the normal way to journal.
  memory_cli.py update M-0001 [--name "..."] [--owner "..."] [--content-file PATH]
      # --content-file here REPLACES the whole body, use `append` unless you mean to overwrite.
  memory_cli.py contributor M-0001 --add "..."
  memory_cli.py delete M-0001
  memory_cli.py render          # regenerate memory.html's embedded data block from memory.json

Every mutating command re-renders memory.html automatically, so the journal viewer is never
stale after a CLI call. `render` alone is only needed if memory.json was hand-edited.
"""
import argparse
import contextlib
import datetime
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA_PATH = os.path.join(ROOT, "data", "memory.json")
HTML_PATH = os.path.join(ROOT, "memory.html")
LOCK_PATH = DATA_PATH + ".lock"


def _now():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


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
                         f"Is another memory_cli.py call running?")
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


def save(db):
    """Writes to a temp file next to the real one, then renames it into place, which is
    atomic on every platform Python supports. Before this, save() truncated the file with
    mode "w" before writing the new content, so a read landing in that window saw an empty,
    unparseable file."""
    tmp_path = DATA_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(db, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp_path, DATA_PATH)


def _find(db, entry_id):
    for e in db["entries"]:
        if e["id"] == entry_id:
            return e
    sys.exit(f"no such entry: {entry_id}")


def _new_id(db):
    seq = db["_meta"]["nextEntrySeq"]
    db["_meta"]["nextEntrySeq"] = seq + 1
    return f'{db["_meta"]["entryIdPrefix"]}{seq:04d}'


def _read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def cmd_list(db, _args):
    if not db["entries"]:
        print("(no journal entries)")
        return
    for e in db["entries"]:
        print(f'{e["id"]}  {e["updatedAt"]}  owner={e["owner"]:<16} {e["name"]}')


def cmd_show(db, args):
    print(json.dumps(_find(db, args.entry_id), indent=2, ensure_ascii=False))


def cmd_create(db, args):
    now = _now()
    content = _read_file(args.content_file) if args.content_file else ""
    contributors = list(dict.fromkeys([args.owner] + (args.contributor or [])))
    entry = {
        "id": _new_id(db),
        "name": args.name,
        "owner": args.owner,
        "createdAt": now,
        "updatedAt": now,
        "contributors": contributors,
        "content": content,
    }
    db["entries"].append(entry)
    save(db)
    render(db)
    print(f'created {entry["id"]}')


def cmd_append(db, args):
    e = _find(db, args.entry_id)
    addition = _read_file(args.content_file)
    author = args.author or e["owner"]
    stamp = f"\n\n--- {_now()} · {author} ---\n{addition}"
    e["content"] = (e.get("content") or "") + stamp
    if author not in e["contributors"]:
        e["contributors"].append(author)
    e["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'appended to {e["id"]}')


def cmd_update(db, args):
    e = _find(db, args.entry_id)
    if args.name:
        e["name"] = args.name
    if args.owner:
        e["owner"] = args.owner
        if args.owner not in e["contributors"]:
            e["contributors"].append(args.owner)
    if args.content_file:
        e["content"] = _read_file(args.content_file)
    e["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'updated {e["id"]}')


def cmd_contributor(db, args):
    e = _find(db, args.entry_id)
    if args.add and args.add not in e["contributors"]:
        e["contributors"].append(args.add)
    e["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'updated contributors on {e["id"]}')


def cmd_delete(db, args):
    e = _find(db, args.entry_id)
    db["entries"].remove(e)
    save(db)
    render(db)
    print(f'deleted {e["id"]}')


def render(db):
    """Regenerate ONLY the embedded <script id="journal-data"> JSON block in memory.html.
    Never touches the surrounding page chrome."""
    if not os.path.exists(HTML_PATH):
        print(f"WARN: {HTML_PATH} not found, skipping render", file=sys.stderr)
        return
    html = open(HTML_PATH, encoding="utf-8").read()
    # json.dumps() doesn't escape "<", so journal content containing "</script>" would
    # otherwise close the data block early and corrupt the page. < is valid JSON, decodes
    # back to "<" transparently in JSON.parse(), and can never be read as a tag by the
    # browser's HTML tokenizer, so this covers "</script>" and the "<!--<script" case too.
    payload = json.dumps(db, indent=2, ensure_ascii=False).replace("<", "\\u003c")
    pattern = re.compile(
        r'(<script id="journal-data" type="application/json">)(.*?)(</script>)',
        re.S,
    )
    new_html, n = pattern.subn(lambda m: m.group(1) + "\n" + payload + "\n" + m.group(3), html, count=1)
    if n == 0:
        sys.exit(f'no <script id="journal-data"> block found in {HTML_PATH}, cannot render')
    # Same tmp-then-os.replace() dance save() uses: the page is what a browser has open,
    # and a crash (or a reload) mid-write would otherwise leave a truncated, unusable file.
    tmp_html = HTML_PATH + ".tmp"
    with open(tmp_html, "w", encoding="utf-8") as fh:
        fh.write(new_html)
    os.replace(tmp_html, HTML_PATH)


def cmd_render(db, _args):
    render(db)
    print("rendered memory.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list"); p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show")
    p.add_argument("entry_id")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("create")
    p.add_argument("--name", required=True)
    p.add_argument("--owner", required=True)
    p.add_argument("--contributor", action="append")
    p.add_argument("--content-file")
    p.set_defaults(fn=cmd_create)

    p = sub.add_parser("append")
    p.add_argument("entry_id")
    p.add_argument("--content-file", required=True)
    p.add_argument("--author")
    p.set_defaults(fn=cmd_append)

    p = sub.add_parser("update")
    p.add_argument("entry_id")
    p.add_argument("--name")
    p.add_argument("--owner")
    p.add_argument("--content-file")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("contributor")
    p.add_argument("entry_id")
    p.add_argument("--add", required=True)
    p.set_defaults(fn=cmd_contributor)

    p = sub.add_parser("delete")
    p.add_argument("entry_id")
    p.set_defaults(fn=cmd_delete)

    p = sub.add_parser("render"); p.set_defaults(fn=cmd_render)

    args = ap.parse_args()
    with locked():
        db = load()
        args.fn(db, args)


if __name__ == "__main__":
    main()
