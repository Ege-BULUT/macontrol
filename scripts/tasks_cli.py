#!/usr/bin/env python3
"""tasks_cli.py: the read/write interface to this workspace's task board.

Fully local: this touches only files under this workspace's data/ directory. Never call
anything network-facing from here. Agents (and humans) use this instead of hand-editing
tasks.json, so ids, timestamps, and the rendered tasks.html stay consistent.

  tasks_cli.py list [--status STATUS] [--tag TAG] [--owner OWNER]
  tasks_cli.py show T-0001
  tasks_cli.py add --title "..." [--status backlog] [--urgency medium] [--tag frontend]
                   [--desc "..."] [--ref design-doc#3 ...] [--blocked-by T-0002 ...]
                   [--related-to T-0005 ...] [--owner "..."] [--actor "..."]
  tasks_cli.py update T-0001 [--status development] [--urgency high] [--owner "..."]
                   [--title "..."] [--desc "..."] [--actor "..."]
                   [--duration-sec 340] [--tokens 12845] [--summary "..."]
      # When --duration-sec/--tokens/--summary are set, a session entry is appended in the
      # same call. Use this instead of a separate `session` command at status transitions.
  tasks_cli.py claim T-0001 --actor "coder-agent"     # atomic: sets assignee + moves to development
      # fails if already claimed (assignee set and != actor). Prevents two agents picking the
      # same task. Re-running with the SAME --actor is idempotent. To hand off, run `release`.
  tasks_cli.py release T-0001 --actor "coder-agent"   # clears assignee so another agent can claim
  tasks_cli.py review T-0001 --verdict approve|request_changes|reject
                   --reviewer "code-reviewer" --notes "..." [--duration-sec N] [--tokens N]
      # records a structured verdict + reviewer + telemetry in one call. Verdict is stored on
      # the task and visible in the board's detail view.
  tasks_cli.py attach T-0001 --file ~/shots/login.png [--label "SS1: login screen"] [--name login.png]
      # copies the image into attachments/ and shows it in the task's detail view
  tasks_cli.py comment T-0001 --author "tester-agent" --text "..." [--role tester|engineer|reviewer|human]
  tasks_cli.py link T-0001 [--blocked-by T-0002] [--related-to T-0005] [--actor "..."]
  tasks_cli.py unlink T-0001 [--blocked-by T-0002] [--related-to T-0005] [--actor "..."]
  tasks_cli.py delete T-0001 [--actor "..."]
      # also drops the deleted id from every other task's blockedBy/relatedTo, so nothing
      # is left pointing at a task that no longer exists.
  tasks_cli.py session T-0001 --agent "code-reviewer" [--duration-sec 340] [--tokens 12345]
                   [--summary "..."] [--started-at ISO] [--ended-at ISO]
      # records one agent's work session on a task: who, how long, how many tokens, what happened.
      # Call this whenever a subagent finishes a piece of work on a task. The Agent tool's
      # completion notification already reports duration_ms/subagent_tokens for exactly this.
  tasks_cli.py render          # regenerate tasks.html's embedded data block from tasks.json

Every mutating command (add/update/claim/release/review/comment/attach/link/session) re-renders tasks.html automatically
and appends a timestamped entry to the task's own `log[]`, a full audit trail of what changed,
who changed it, and when, visible in the task's detail view. `render` alone is only needed if
tasks.json was hand-edited.
"""
import argparse
import contextlib
import datetime
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA_PATH = os.path.join(ROOT, "data", "tasks.json")
HTML_PATH = os.path.join(ROOT, "tasks.html")
LOCK_PATH = DATA_PATH + ".lock"
ATTACH_DIR = os.path.join(ROOT, "attachments")
ROADMAP_DATA_PATH = os.path.join(ROOT, "data", "roadmap.json")
VALID_URGENCY = ("low", "medium", "high", "critical")
VALID_ROLES = ("tester", "engineer", "reviewer", "human")


def _now():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def _warn_if_unknown_milestone(milestone_id):
    """A task's milestone is a soft reference into a different file, not another task, so
    this warns instead of refusing outright. roadmap.json might not exist in a bare setup,
    or the milestone might be added moments later. It's still worth catching the common typo
    case (a milestone id that will never resolve to anything on the roadmap page)."""
    if not milestone_id or not os.path.exists(ROADMAP_DATA_PATH):
        return
    try:
        roadmap = json.load(open(ROADMAP_DATA_PATH, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    known = {m["id"] for m in roadmap.get("milestones", [])}
    if milestone_id not in known:
        print(f"WARN: milestone {milestone_id!r} isn't in roadmap.json yet. The task will "
              f"still be saved, but its \"Tasks →\" link won't show up anywhere until a "
              f"milestone with that id exists", file=sys.stderr)


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
                # A lock file older than the timeout almost certainly means a previous run
                # crashed before cleaning up, not that it's still legitimately held.
                try:
                    if time.time() - os.path.getmtime(LOCK_PATH) > timeout:
                        os.remove(LOCK_PATH)
                        continue
                except OSError:
                    pass
                sys.exit(f"could not acquire {LOCK_PATH} within {timeout}s. "
                         f"Is another tasks_cli.py call running?")
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
    """Writes to a temp file next to the real one, then renames it into place. os.replace()
    is atomic on every platform Python supports, so a reader can never observe a half
    written file. Before this, save() truncated the file with mode "w" before writing the
    new content, so a read landing in that window saw an empty, unparseable file."""
    tmp_path = DATA_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(db, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp_path, DATA_PATH)


def _valid_statuses(db):
    return db["_meta"]["columns"]


def _find(db, task_id):
    for t in db["tasks"]:
        if t["id"] == task_id:
            return t
    sys.exit(f"no such task: {task_id}")


def _new_id(db):
    seq = db["_meta"]["nextTaskSeq"]
    db["_meta"]["nextTaskSeq"] = seq + 1
    return f'{db["_meta"]["taskIdPrefix"]}{seq:04d}'


def _log_event(task, event, detail="", actor="unspecified"):
    """Every mutating command calls this, one line, no agent has to remember to log anything
    separately. `log[]` is the WHAT-changed/WHO/WHEN audit trail; it's distinct from
    `sessions[]` (the effort/cost ledger, see cmd_session), which nothing can auto-measure."""
    task.setdefault("log", []).append({
        "ts": _now(), "actor": actor or "unspecified", "event": event, "detail": detail,
    })


def cmd_list(db, args):
    tasks = db["tasks"]
    if args.status:
        # Without this, a typo'd status is indistinguishable from a genuinely empty column.
        if args.status not in _valid_statuses(db):
            sys.exit(f"invalid status {args.status!r}, must be one of {_valid_statuses(db)}")
        tasks = [t for t in tasks if t["status"] == args.status]
    if args.tag:
        tasks = [t for t in tasks if t.get("tag") == args.tag]
    if args.milestone:
        tasks = [t for t in tasks if t.get("milestone") == args.milestone]
    if args.owner:
        tasks = [t for t in tasks if t.get("owner") == args.owner]
    if not tasks:
        print("(no matching tasks)")
        return
    for t in tasks:
        print(f'{t["id"]}  [{t["status"]:<17}] {t.get("urgency","-"):<8} {t["title"]}')


def cmd_show(db, args):
    t = _find(db, args.task_id)
    print(json.dumps(t, indent=2, ensure_ascii=False))


def cmd_add(db, args):
    status = args.status or db["_meta"]["columns"][0]
    if status not in _valid_statuses(db):
        sys.exit(f"invalid status {status!r}, must be one of {_valid_statuses(db)}")
    if args.urgency not in VALID_URGENCY:
        sys.exit(f"invalid urgency {args.urgency!r}, must be one of {VALID_URGENCY}")
    new_id = _new_id(db)
    blocked_by = args.blocked_by or []
    related_to = args.related_to or []
    for other_id in blocked_by + related_to:
        if other_id == new_id:
            sys.exit(f"a task can't block or relate to itself")
        _find(db, other_id)  # exits with a clear error if it doesn't exist
    if args.milestone:
        _warn_if_unknown_milestone(args.milestone)

    now = _now()
    task = {
        "id": new_id,
        "title": args.title,
        "description": args.desc or "",
        "status": status,
        "urgency": args.urgency,
        "tag": args.tag or None,
        "milestone": args.milestone or None,
        "refs": args.ref or [],
        "blockedBy": blocked_by,
        "relatedTo": related_to,
        "owner": args.owner or "",
        "createdAt": now,
        "updatedAt": now,
        "comments": [],
        "log": [],
        "sessions": [],
    }
    _log_event(task, "created", f"status={status}, urgency={args.urgency}", getattr(args, "actor", None))
    db["tasks"].append(task)
    # "related to" is symmetric, so the other task gets the backlink too. Without this, the
    # same relationship would look different depending on whether it was created here or
    # through `link --related-to`, which does write both sides.
    for other_id in related_to:
        other = _find(db, other_id)
        if new_id not in other["relatedTo"]:
            other["relatedTo"].append(new_id)
            _log_event(other, "linked", f"relatedTo += {new_id}", getattr(args, "actor", None))
    save(db)
    render(db)
    print(f'created {task["id"]}')


def cmd_update(db, args):
    t = _find(db, args.task_id)
    changes = []
    if args.status is not None:
        if args.status not in _valid_statuses(db):
            sys.exit(f"invalid status {args.status!r}, must be one of {_valid_statuses(db)}")
        if args.status != t["status"]:
            changes.append(f'status: {t["status"]} -> {args.status}')
        t["status"] = args.status
    if args.urgency is not None:
        if args.urgency not in VALID_URGENCY:
            sys.exit(f"invalid urgency {args.urgency!r}, must be one of {VALID_URGENCY}")
        if args.urgency != t["urgency"]:
            changes.append(f'urgency: {t["urgency"]} -> {args.urgency}')
        t["urgency"] = args.urgency
    if args.title is not None:
        if not args.title:
            sys.exit("--title cannot be empty")
        if args.title != t["title"]:
            changes.append("title edited")
        t["title"] = args.title
    if args.desc is not None:
        if args.desc != t["description"]:
            changes.append("description edited")
        t["description"] = args.desc
    if args.owner is not None:
        if args.owner != t["owner"]:
            changes.append(f'owner: {t["owner"] or "(none)"} -> {args.owner or "(none)"}')
        t["owner"] = args.owner
    if args.milestone is not None:
        if args.milestone != t.get("milestone"):
            changes.append(f'milestone: {t.get("milestone") or "(none)"} -> {args.milestone}')
        if args.milestone:
            _warn_if_unknown_milestone(args.milestone)
        t["milestone"] = args.milestone
    # A re-set to the value a field already had isn't an edit. Logging it anyway (and bumping
    # updatedAt) buried the real changes in "no change" lines and made the board look busy
    # every time an agent re-asserted a status it had already set.
    has_session = (args.duration_sec is not None or args.tokens is not None or args.summary)
    if not changes and not has_session:
        print(f'no changes on {t["id"]}')
        return
    _log_event(t, "updated", "; ".join(changes) if changes else "(no field changes; session logged)", args.actor)
    # Optional session entry. Agents that pass --duration-sec/--tokens/--summary here don't
    # need a separate `session` call. Cuts one CLI invocation per status transition.
    if has_session:
        t.setdefault("sessions", []).append({
            "ts": _now(),
            "agent": args.actor or "unspecified",
            "startedAt": "",
            "endedAt": "",
            "durationSec": args.duration_sec,
            "tokens": args.tokens,
            "summary": args.summary or "",
        })
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'updated {t["id"]}')


def cmd_claim(db, args):
    """Atomically claim a task for an agent. Fails if a different agent already holds the
    claim. The CLI lock around load+save guarantees two parallel subagents can't both win.
    even if they call `claim` at the same instant, the second one will see the first's
    assignee and exit non-zero."""
    t = _find(db, args.task_id)
    actor = args.actor or "unspecified"
    existing = t.get("assignee")
    if existing and existing != actor:
        sys.exit(f'{t["id"]} is already claimed by {existing!r}; '
                 f'cannot claim as {actor!r}. Run `release` first or pick another task.')
    changes = []
    if t.get("assignee") != actor:
        t["assignee"] = actor
        changes.append(f"assignee: {existing or '(none)'} -> {actor}")
    if t["status"] not in ("development", "ready_for_review", "testing"):
        # Move to development automatically. A claim without a status bump means the board
        # never reflects that work started, and reviewers can't pick it up.
        changes.append(f"status: {t['status']} -> development")
        t["status"] = "development"
    if not changes:
        print(f'no changes on {t["id"]}')
        return
    _log_event(t, "claimed", "; ".join(changes), actor)
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'claimed {t["id"]} for {actor}')


def cmd_release(db, args):
    """Drop a claim so another agent can pick the task up. Only the current assignee
    (or unspecified force via --force) can release."""
    t = _find(db, args.task_id)
    actor = args.actor or "unspecified"
    existing = t.get("assignee")
    if not existing:
        print(f'{t["id"]} has no assignee; nothing to release')
        return
    if existing != actor and not args.force:
        sys.exit(f'{t["id"]} is claimed by {existing!r}; '
                 f'only {existing!r} can release it. Pass --force to override.')
    del t["assignee"]
    _log_event(t, "released", f"assignee was {existing!r}", actor)
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'released {t["id"]}')


def cmd_review(db, args):
    """Record a structured reviewer verdict. Verdict is stored on the task; duration/tokens
    feed the same sessions[] ledger a coder's `update` does, so the cost rollup covers both."""
    t = _find(db, args.task_id)
    if args.verdict not in ("approve", "request_changes", "reject"):
        sys.exit(f"invalid verdict {args.verdict!r}")
    t["verdict"] = args.verdict
    t["verdictBy"] = args.reviewer
    t["verdictAt"] = _now()
    t["verdictNotes"] = args.notes or ""
    # A verdict also counts as a session entry. Reviewers spend time and tokens too.
    if args.duration_sec is not None or args.tokens is not None or args.notes:
        t.setdefault("sessions", []).append({
            "ts": _now(),
            "agent": args.reviewer,
            "startedAt": "",
            "endedAt": "",
            "durationSec": args.duration_sec,
            "tokens": args.tokens,
            "summary": f"verdict={args.verdict}: {(args.notes or '')[:80]}",
        })
    detail = f"verdict={args.verdict} by {args.reviewer}"
    if args.duration_sec is not None:
        detail += f", {args.duration_sec:.0f}s"
    if args.tokens is not None:
        detail += f", {args.tokens} tokens"
    _log_event(t, "reviewed", detail, args.reviewer)
    # Auto-advance: approve -> accepted, reject -> rejected. request_changes leaves it at
    # ready_for_review (or wherever it was) so the coder picks it back up.
    if args.verdict == "approve":
        t["status"] = "accepted"
    elif args.verdict == "reject":
        t["status"] = "rejected"
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'reviewed {t["id"]}: {args.verdict}')


def cmd_comment(db, args):
    t = _find(db, args.task_id)
    role = args.role or "human"
    if role not in VALID_ROLES:
        sys.exit(f"invalid role {role!r}, must be one of {VALID_ROLES}")
    t.setdefault("comments", []).append({
        "author": args.author,
        "role": role,
        "date": _now(),
        "text": args.text,
    })
    _log_event(t, "comment", f'{args.text[:80]}{"…" if len(args.text) > 80 else ""}', args.author)
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'commented on {t["id"]}')


def cmd_attach(db, args):
    """Attach a screenshot (or any image) to a task.

    The file is copied into the workspace's attachments/ directory and stored as a
    workspace-relative path, so tasks.html can show it straight off disk over file://
    with no server involved. Same rule as the rest of the workspace: fully local, the
    image never leaves the machine.
    """
    t = _find(db, args.task_id)
    src = os.path.abspath(os.path.expanduser(args.file))
    if not os.path.isfile(src):
        sys.exit(f"no such file: {src}")
    name = args.name or os.path.basename(src)
    # the path is written into the page as an <img src>, so keep it a plain filename:
    # a name with a separator in it could point outside attachments/ entirely.
    if os.path.basename(name) != name or name in ("", ".", ".."):
        sys.exit(f"--name must be a plain filename, got {name!r}")
    os.makedirs(ATTACH_DIR, exist_ok=True)
    dst = os.path.join(ATTACH_DIR, name)
    if os.path.abspath(src) != os.path.abspath(dst):
        shutil.copyfile(src, dst)
    rel = "attachments/" + name
    entry = {"file": rel, "label": args.label or "", "addedAt": _now()}
    items = t.setdefault("attachments", [])
    # re-attaching the same file under the same label refreshes it instead of adding a
    # second identical thumbnail (agents re-run their own commands more often than not)
    for existing in items:
        if existing.get("file") == rel and existing.get("label") == entry["label"]:
            existing.update(entry)
            break
    else:
        items.append(entry)
    _log_event(t, "attached", f'{rel}{" (" + entry["label"] + ")" if entry["label"] else ""}', args.actor)
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'attached {rel} to {t["id"]}')


def cmd_link(db, args):
    t = _find(db, args.task_id)
    if args.blocked_by == t["id"] or args.related_to == t["id"]:
        sys.exit("a task can't block or relate to itself")
    changed = False
    if args.blocked_by:
        _find(db, args.blocked_by)  # must exist
        if args.blocked_by not in t["blockedBy"]:
            t["blockedBy"].append(args.blocked_by)
            _log_event(t, "linked", f"blockedBy += {args.blocked_by}", args.actor)
            changed = True
    if args.related_to:
        other = _find(db, args.related_to)
        if args.related_to not in t["relatedTo"]:
            t["relatedTo"].append(args.related_to)
            _log_event(t, "linked", f"relatedTo += {args.related_to}", args.actor)
            changed = True
        if t["id"] not in other["relatedTo"]:
            other["relatedTo"].append(t["id"])
            _log_event(other, "linked", f"relatedTo += {t['id']}", args.actor)
            changed = True
    # Re-linking an existing link is a no-op, so it doesn't belong in the audit trail. Mirrors
    # cmd_unlink, which has always been quiet when there was nothing to remove.
    if not changed:
        print(f'nothing to link on {t["id"]}')
        return
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'linked {t["id"]}')


def cmd_unlink(db, args):
    t = _find(db, args.task_id)
    changed = False
    if args.blocked_by and args.blocked_by in t["blockedBy"]:
        t["blockedBy"].remove(args.blocked_by)
        _log_event(t, "unlinked", f"blockedBy -= {args.blocked_by}", args.actor)
        changed = True
    if args.related_to and args.related_to in t["relatedTo"]:
        t["relatedTo"].remove(args.related_to)
        _log_event(t, "unlinked", f"relatedTo -= {args.related_to}", args.actor)
        changed = True
        other = next((x for x in db["tasks"] if x["id"] == args.related_to), None)
        if other and t["id"] in other["relatedTo"]:
            other["relatedTo"].remove(t["id"])
            _log_event(other, "unlinked", f"relatedTo -= {t['id']}", args.actor)
    if not changed:
        print(f'nothing to unlink on {t["id"]}')
        return
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'unlinked {t["id"]}')


def cmd_delete(db, args):
    t = _find(db, args.task_id)
    db["tasks"].remove(t)
    # A deleted task's id is now meaningless as a reference, so drop it from every other
    # task's blockedBy/relatedTo instead of leaving a permanent "(unknown)" chip behind.
    for other in db["tasks"]:
        if t["id"] in other.get("blockedBy", []):
            other["blockedBy"].remove(t["id"])
            _log_event(other, "unlinked", f"blockedBy -= {t['id']} (deleted)", args.actor)
        if t["id"] in other.get("relatedTo", []):
            other["relatedTo"].remove(t["id"])
            _log_event(other, "unlinked", f"relatedTo -= {t['id']} (deleted)", args.actor)
    save(db)
    render(db)
    print(f'deleted {t["id"]}')


def cmd_session(db, args):
    """Log one agent's work session on a task: who, how long, how many tokens, what happened.
    The CLI can't measure this itself. Pass it explicitly, typically right after a subagent's
    Agent-tool completion notification reports duration_ms/subagent_tokens for the work it just did."""
    t = _find(db, args.task_id)
    session = {
        "ts": _now(),
        "agent": args.agent,
        "startedAt": args.started_at or "",
        "endedAt": args.ended_at or "",
        "durationSec": args.duration_sec,
        "tokens": args.tokens,
        "summary": args.summary or "",
    }
    t.setdefault("sessions", []).append(session)
    detail = f"agent={args.agent}"
    if args.duration_sec is not None:
        detail += f", {args.duration_sec:.0f}s"
    if args.tokens is not None:
        detail += f", {args.tokens} tokens"
    _log_event(t, "session", detail, args.agent)
    t["updatedAt"] = _now()
    save(db)
    render(db)
    print(f'logged session on {t["id"]}')


def render(db):
    """Regenerate ONLY the embedded <script id="board-data"> JSON block in tasks.html.
    Never touches the surrounding page chrome, so hand-edited CSS/layout survives every
    render."""
    if not os.path.exists(HTML_PATH):
        print(f"WARN: {HTML_PATH} not found, skipping render", file=sys.stderr)
        return
    html = open(HTML_PATH, encoding="utf-8").read()
    # json.dumps() doesn't escape "<", so a title/comment/description containing "</script>"
    # would otherwise close the data block early and corrupt the page. < is valid JSON,
    # decodes back to "<" transparently in JSON.parse(), and can never be read as a tag by
    # the browser's HTML tokenizer, so this covers "</script>" and the "<!--<script" case too.
    payload = json.dumps(db, indent=2, ensure_ascii=False).replace("<", "\\u003c")
    pattern = re.compile(
        r'(<script id="board-data" type="application/json">)(.*?)(</script>)',
        re.S,
    )
    new_html, n = pattern.subn(lambda m: m.group(1) + "\n" + payload + "\n" + m.group(3), html, count=1)
    if n == 0:
        sys.exit(f'no <script id="board-data"> block found in {HTML_PATH}, cannot render')
    # Same tmp-then-os.replace() dance save() uses: the page is what a browser has open,
    # and a crash (or a reload) mid-write would otherwise leave a truncated, unusable file.
    tmp_html = HTML_PATH + ".tmp"
    with open(tmp_html, "w", encoding="utf-8") as fh:
        fh.write(new_html)
    os.replace(tmp_html, HTML_PATH)


def cmd_render(db, _args):
    render(db)
    print("rendered tasks.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list")
    p.add_argument("--status")
    p.add_argument("--tag")
    p.add_argument("--milestone")
    p.add_argument("--owner")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show")
    p.add_argument("task_id")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("add")
    p.add_argument("--title", required=True)
    p.add_argument("--status")
    p.add_argument("--urgency", default="medium")
    p.add_argument("--tag")
    p.add_argument("--milestone")
    p.add_argument("--desc")
    p.add_argument("--ref", action="append")
    p.add_argument("--blocked-by", action="append")
    p.add_argument("--related-to", action="append")
    p.add_argument("--owner")
    p.add_argument("--actor", help="who/what is creating this (for the log), defaults to unspecified")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("update")
    p.add_argument("task_id")
    p.add_argument("--status")
    p.add_argument("--urgency")
    p.add_argument("--title")
    p.add_argument("--desc")
    p.add_argument("--owner")
    p.add_argument("--milestone")
    p.add_argument("--actor", help="who/what is making this change (for the log)")
    # Optional session telemetry. When any of these is set, a session entry is appended
    # alongside the field-change log. Use this at status transitions instead of a separate
    # `session` call so the audit trail is one command, not two.
    p.add_argument("--duration-sec", type=float, dest="duration_sec",
                   help="wall-clock seconds the agent spent (Agent.tool.duration_ms/1000)")
    p.add_argument("--tokens", type=int, help="tokens the agent spent (Agent.tool.subagent_tokens)")
    p.add_argument("--summary", help="one line: what the agent actually did")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("claim")
    p.add_argument("task_id")
    p.add_argument("--actor", required=True, help="agent name claiming this task")
    p.set_defaults(fn=cmd_claim)

    p = sub.add_parser("release")
    p.add_argument("task_id")
    p.add_argument("--actor", required=True, help="agent name releasing the claim (must match assignee, unless --force)")
    p.add_argument("--force", action="store_true", help="release even if --actor doesn't match current assignee")
    p.set_defaults(fn=cmd_release)

    p = sub.add_parser("review")
    p.add_argument("task_id")
    p.add_argument("--verdict", required=True, choices=("approve", "request_changes", "reject"))
    p.add_argument("--reviewer", required=True, help="agent name issuing the verdict")
    p.add_argument("--notes", help="what the reviewer found / why")
    p.add_argument("--duration-sec", type=float, dest="duration_sec")
    p.add_argument("--tokens", type=int)
    p.set_defaults(fn=cmd_review)

    p = sub.add_parser("comment")
    p.add_argument("task_id")
    p.add_argument("--author", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--role")
    p.set_defaults(fn=cmd_comment)

    p = sub.add_parser("attach")
    p.add_argument("task_id")
    p.add_argument("--file", required=True, help="image file to attach (copied into attachments/)")
    p.add_argument("--label", help="short caption shown under the thumbnail")
    p.add_argument("--name", help="filename to store it under (default: the source filename)")
    p.add_argument("--actor", help="who/what is attaching this (for the log)")
    p.set_defaults(fn=cmd_attach)

    p = sub.add_parser("link")
    p.add_argument("task_id")
    p.add_argument("--blocked-by")
    p.add_argument("--related-to")
    p.add_argument("--actor", help="who/what is making this link (for the log)")
    p.set_defaults(fn=cmd_link)

    p = sub.add_parser("unlink")
    p.add_argument("task_id")
    p.add_argument("--blocked-by")
    p.add_argument("--related-to")
    p.add_argument("--actor", help="who/what is removing this link (for the log)")
    p.set_defaults(fn=cmd_unlink)

    p = sub.add_parser("delete")
    p.add_argument("task_id")
    p.add_argument("--actor", help="who/what is deleting this task (logged on any other task whose blockedBy/relatedTo pointed at it)")
    p.set_defaults(fn=cmd_delete)

    p = sub.add_parser("session")
    p.add_argument("task_id")
    p.add_argument("--agent", required=True, help="subagent name/type, e.g. code-reviewer, general-purpose, fork")
    p.add_argument("--duration-sec", type=float, help="wall-clock seconds spent (from the Agent tool's duration_ms/1000)")
    p.add_argument("--tokens", type=int, help="tokens spent (from the Agent tool's subagent_tokens)")
    p.add_argument("--summary", help="one line: what the agent actually did")
    p.add_argument("--started-at", help="ISO timestamp, if known, alternative/addition to --duration-sec")
    p.add_argument("--ended-at", help="ISO timestamp, if known")
    p.set_defaults(fn=cmd_session)

    p = sub.add_parser("render")
    p.set_defaults(fn=cmd_render)

    args = ap.parse_args()
    with locked():
        db = load()
        args.fn(db, args)


if __name__ == "__main__":
    main()
