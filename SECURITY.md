# Security policy

macontrol moves files to the Trash on the user's behalf, so a bug that makes it touch the wrong file is a security problem, not only a bug.

## Supported versions

Only the latest 0.x preview gets fixes. Older previews are not patched: update to the newest release on the [releases page](https://github.com/Ege-BULUT/macontrol/releases).

| Version | Supported |
|---|---|
| Latest 0.x preview (0.1.1 today) | Yes |
| Older previews | No |

## Reporting a vulnerability

Report privately. Do not open a public issue, pull request or discussion.

- **Once the repository is public:** use GitHub's private vulnerability reporting (the **Security** tab, then **Report a vulnerability**).
- **Until then:** email **egebulut.iletisim@outlook.com** with "macontrol security" in the subject.

Please include:

- the macontrol version (Macontrol › About Macontrol, or the zip name) and the macOS version
- what an attacker can make macontrol do, and what they need first (a crafted download, a local account, a running process)
- steps or a script that reproduce it, ideally building the file tree in a temporary folder
- whether you plan to publish, and when

## What counts

- Anything that can make macontrol delete, move or expose files it should not. For example: getting past the protected-path policy, a link or folder swap between scan and move that sends a different file to the Trash, a crafted file name or cleanup rule that reaches outside its folder, Undo putting an item back somewhere other than where it came from, or the undo journal becoming readable by another user.
- Privilege escalation through the privileged helper planned for 0.2 (`macontrol-priv`). For example: making it act on a path the user did not approve, or running code of your choice as root.
- Anything that makes macontrol run a program or script it was not built to run.

## What does not count

- macontrol doing what the docs say, such as moving an item you selected to the Trash.
- The known limits in the [README](README.md#install): the build is not notarized and is ad-hoc signed, and Full Disk Access has to be granted again after an update.
- Attacks that already need root, or full control of the user's account.

A removal that is wrong but not exploitable, such as a Clean rule that is too broad, is a safety bug: use the **Safety report** issue form.

## What to expect

- An acknowledgement within 7 days.
- An assessment within 14 days: whether it is confirmed, how severe it is, and the plan.
- Confirmed issues are fixed in the next release. The fix lands with a test that fails without it, and the changelog credits the reporter unless they prefer not to be named.
- Updates at least every 14 days until the issue is closed. Please keep it private until a fixed release is out, or until we agree on a date.
