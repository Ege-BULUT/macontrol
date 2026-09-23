#!/usr/bin/env python3
"""analysis_cli.py: the read/write interface to this project's review-findings board.

Fully local: this touches only files under this workspace's data/ directory. Never call
anything network-facing from here. A finding is one reviewable defect or improvement, filed
under one or more categories, with a priority, an effort estimate, and the before/after/how
of the fix. The diagram is built from however many categories this workspace defines, so the
count is the reviewer's call, not a fixed three.

  analysis_cli.py list [--status open] [--priority critical] [--category bug]
  analysis_cli.py show F-0001
  analysis_cli.py add --title "..." --category bug [--category perf]
      [--priority blocker|critical|high|medium|low] [--effort S|M|L|XL] [--hours 2]
      [--where "file.py fn"] [--problem-file PATH] [--before-file PATH]
      [--after-file PATH] [--how-file PATH]
  analysis_cli.py update F-0001 [--title "..."] [--priority ...] [--effort ...] [--hours ...]
      [--where "..."] [--problem-file PATH] [--before-file PATH] [--after-file PATH] [--how-file PATH]
  analysis_cli.py category F-0001 [--add ux] [--remove perf]
  analysis_cli.py status F-0001 --set fixed [--note "how it was verified"]
  analysis_cli.py meta [--subject "..."] [--reviewer "..."] [--reviewed-at 2026-08-24]
      [--category-label bug="Bug fixes"] [--category-note bug="..."]
  analysis_cli.py remove F-0001
  analysis_cli.py render        # regenerate analysis.html's embedded data block from analysis.json

Every mutating command re-renders analysis.html automatically, so the report is never stale
after a CLI call. `render` alone is only needed if analysis.json was hand-edited.

The page draws a Venn diagram of the three categories: position shows which categories a
finding belongs to, disc size shows effort, disc colour shows priority. Overlap is the point,
so keep categories to three; a finding that fits none of them is a task, not a finding, and
belongs on the board instead.
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
DATA_PATH = os.path.join(ROOT, "data", "analysis.json")
HTML_PATH = os.path.join(ROOT, "analysis.html")
LOCK_PATH = DATA_PATH + ".lock"

PRIORITIES = ("blocker", "critical", "high", "medium", "low")
EFFORTS = ("S", "M", "L", "XL")
STATUSES = ("open", "fixed", "wontfix")


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
                         f"Is another analysis_cli.py call running?")
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
    atomic on every platform Python supports."""
    tmp_path = DATA_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(db, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp_path, DATA_PATH)


def _find(db, finding_id):
    for f in db["findings"]:
        if f["id"] == finding_id:
            return f
    sys.exit(f"no such finding: {finding_id}")


def _new_id(db):
    seq = db["_meta"]["nextFindingSeq"]
    db["_meta"]["nextFindingSeq"] = seq + 1
    return f'{db["_meta"]["findingIdPrefix"]}{seq:04d}'


def _read_file(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _check_categories(db, names):
    known = set(db["_meta"]["categories"])
    unknown = [n for n in names if n not in known]
    if unknown:
        sys.exit(f'unknown category {", ".join(unknown)}. '
                 f'This workspace defines: {", ".join(sorted(known))}. '
                 f'Rename one with `meta --category-label`, or file this as a task instead.')
    if len(names) > len(known):
        sys.exit(f"a finding cannot sit in more categories than this workspace defines "
                 f"({len(known)}). Define another with `meta --category-label key=Label`.")


def _sort_key(db, f):
    order = {p: i for i, p in enumerate(PRIORITIES)}
    return (order.get(f["priority"], len(PRIORITIES)), f["id"])


def cmd_list(db, args):
    rows = db["findings"]
    if args.status:
        rows = [f for f in rows if f["status"] == args.status]
    if args.priority:
        rows = [f for f in rows if f["priority"] == args.priority]
    if args.category:
        rows = [f for f in rows if args.category in f["categories"]]
    if not rows:
        print("(no findings match)")
        return
    for f in sorted(rows, key=lambda f: _sort_key(db, f)):
        cats = ",".join(f["categories"])
        print(f'{f["id"]}  {f["priority"]:<8} {f["effort"]:<2} {f["status"]:<7} {cats:<16} {f["title"]}')


def cmd_show(db, args):
    print(json.dumps(_find(db, args.finding_id), indent=2, ensure_ascii=False))


def cmd_add(db, args):
    categories = list(dict.fromkeys(args.category))
    _check_categories(db, categories)
    now = _now()
    finding = {
        "id": _new_id(db),
        "title": args.title,
        "categories": categories,
        "priority": args.priority,
        "effort": args.effort,
        "hours": args.hours,
        "status": "open",
        "where": args.where or "",
        "problem": _read_file(args.problem_file) if args.problem_file else "",
        "before": _read_file(args.before_file) if args.before_file else "",
        "after": _read_file(args.after_file) if args.after_file else "",
        "how": _read_file(args.how_file) if args.how_file else "",
        "verified": "",
        "createdAt": now,
        "updatedAt": now,
    }
    db["findings"].append(finding)
    save(db)
    render(db)
    print(f'added {finding["id"]}')


def cmd_update(db, args):
    f = _find(db, args.finding_id)
    for attr, key in (("title", "title"), ("where", "where"), ("priority", "priority"),
                      ("effort", "effort")):
        value = getattr(args, attr)
        if value:
            f[key] = value
    if args.hours is not None:
        f["hours"] = args.hours
    for attr, key in (("problem_file", "problem"), ("before_file", "before"),
                      ("after_file", "after"), ("how_file", "how")):
        path = getattr(args, attr)
        if path:
            f[key] = _read_file(path)
    f["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'updated {f["id"]}')


def cmd_category(db, args):
    f = _find(db, args.finding_id)
    cats = list(f["categories"])
    for name in args.remove or []:
        if name in cats:
            cats.remove(name)
    for name in args.add or []:
        if name not in cats:
            cats.append(name)
    _check_categories(db, cats)
    if not cats:
        sys.exit("a finding needs at least one category, otherwise it cannot be placed on the diagram")
    f["categories"] = cats
    f["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'{f["id"]} is now in: {", ".join(cats)}')


def cmd_status(db, args):
    f = _find(db, args.finding_id)
    f["status"] = args.set
    if args.note:
        f["verified"] = args.note
    f["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'{f["id"]} -> {args.set}')


def _kv(pairs, what):
    out = {}
    for raw in pairs or []:
        if "=" not in raw:
            sys.exit(f'--{what} takes key=value, got "{raw}"')
        key, value = raw.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def cmd_meta(db, args):
    meta = db["_meta"]
    if args.subject:
        meta["subject"] = args.subject
    if args.reviewer:
        meta["reviewer"] = args.reviewer
    if args.reviewed_at:
        meta["reviewed_at"] = args.reviewed_at
        meta["reviewedAt"] = args.reviewed_at
    for key, label in _kv(args.category_label, "category-label").items():
        meta["categories"].setdefault(key, {"label": key, "note": ""})["label"] = label
    for key, note in _kv(args.category_note, "category-note").items():
        meta["categories"].setdefault(key, {"label": key, "note": ""})["note"] = note
    for key in args.category_remove or []:
        if key not in meta["categories"]:
            sys.exit(f'unknown category "{key}"')
        used = [f["id"] for f in db["findings"] if key in (f.get("categories") or [])]
        if used:
            sys.exit(f'{key} is still on {", ".join(used)}. Move those first with '
                     f'`category <id> --remove {key} --add <other>`.')
        if len(meta["categories"]) <= 1:
            sys.exit("a workspace needs at least one category")
        del meta["categories"][key]
    save(db)
    render(db)
    print("updated review metadata")


def cmd_remove(db, args):
    f = _find(db, args.finding_id)
    db["findings"].remove(f)
    save(db)
    render(db)
    print(f'removed {f["id"]}')


def render(db):
    """Regenerate ONLY the embedded <script id="analysis-data"> JSON block in analysis.html.
    Never touches the surrounding page chrome."""
    if not os.path.exists(HTML_PATH):
        print(f"WARN: {HTML_PATH} not found, skipping render", file=sys.stderr)
        return
    html = open(HTML_PATH, encoding="utf-8").read()
    # json.dumps() doesn't escape "<", so a before/after snippet containing "</script>" would
    # otherwise close the data block early and corrupt the page. < is valid JSON, decodes
    # back to "<" transparently in JSON.parse(), and can never be read as a tag by the
    # browser's HTML tokenizer. Code snippets are exactly the field most likely to carry one.
    payload = json.dumps(db, indent=2, ensure_ascii=False).replace("<", "\\u003c")
    pattern = re.compile(
        r'(<script id="analysis-data" type="application/json">)(.*?)(</script>)',
        re.S,
    )
    new_html, n = pattern.subn(lambda m: m.group(1) + "\n" + payload + "\n" + m.group(3), html, count=1)
    if n == 0:
        sys.exit(f'no <script id="analysis-data"> block found in {HTML_PATH}, cannot render')
    tmp_html = HTML_PATH + ".tmp"
    with open(tmp_html, "w", encoding="utf-8") as fh:
        fh.write(new_html)
    os.replace(tmp_html, HTML_PATH)


def cmd_render(db, _args):
    render(db)
    print("rendered analysis.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list")
    p.add_argument("--status", choices=STATUSES)
    p.add_argument("--priority", choices=PRIORITIES)
    p.add_argument("--category")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show")
    p.add_argument("finding_id")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("add")
    p.add_argument("--title", required=True)
    p.add_argument("--category", action="append", required=True,
                   help="repeat for a finding that sits in more than one")
    p.add_argument("--priority", choices=PRIORITIES, default="medium")
    p.add_argument("--effort", choices=EFFORTS, default="M")
    p.add_argument("--hours", type=float, default=0)
    p.add_argument("--where", help="file and function the finding lives in")
    p.add_argument("--problem-file")
    p.add_argument("--before-file")
    p.add_argument("--after-file")
    p.add_argument("--how-file")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("update")
    p.add_argument("finding_id")
    p.add_argument("--title")
    p.add_argument("--priority", choices=PRIORITIES)
    p.add_argument("--effort", choices=EFFORTS)
    p.add_argument("--hours", type=float)
    p.add_argument("--where")
    p.add_argument("--problem-file")
    p.add_argument("--before-file")
    p.add_argument("--after-file")
    p.add_argument("--how-file")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("category")
    p.add_argument("finding_id")
    p.add_argument("--add", action="append")
    p.add_argument("--remove", action="append")
    p.set_defaults(fn=cmd_category)

    p = sub.add_parser("status")
    p.add_argument("finding_id")
    p.add_argument("--set", required=True, choices=STATUSES)
    p.add_argument("--note", help="how the fix was verified, shown in the details section")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("meta")
    p.add_argument("--subject")
    p.add_argument("--reviewer")
    p.add_argument("--reviewed-at")
    p.add_argument("--category-label", action="append", metavar="KEY=LABEL")
    p.add_argument("--category-note", action="append", metavar="KEY=NOTE")
    p.add_argument("--category-remove", action="append", metavar="KEY",
                   help="drop a category; refuses while any finding still sits in it")
    p.set_defaults(fn=cmd_meta)

    p = sub.add_parser("remove")
    p.add_argument("finding_id")
    p.set_defaults(fn=cmd_remove)

    p = sub.add_parser("render")
    p.set_defaults(fn=cmd_render)

    args = ap.parse_args()
    with locked():
        db = load()
        args.fn(db, args)


if __name__ == "__main__":
    main()
