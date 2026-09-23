#!/bin/sh
# Shows that moving a LaunchAgent plist to the Trash (what Pearcleaner's uninstall does,
# Logic/UndoManager.swift:111-135) leaves the job loaded, running and KeepAlive-respawning.
# Local only: loads a throwaway /bin/sleep agent into gui/$UID and boots it out at the end.
set -u
L=com.macontrol.research.launchdprobe
D=$(mktemp -d); U=$(id -u)
cat > "$D/$L.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$L</string>
<key>ProgramArguments</key><array><string>/bin/sleep</string><string>300</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
EOF
show() { launchctl print "gui/$U/$L" 2>&1 | grep -E '^\s*(state|pid|runs) =' | head -3; }
launchctl bootstrap "gui/$U" "$D/$L.plist"; sleep 1
echo "loaded:"; show
mkdir "$D/Trash"; /bin/mv "$D/$L.plist" "$D/Trash/"; sleep 1
echo "after mv of the plist:"; show
kill "$(launchctl print "gui/$U/$L" | awk '/^\tpid =/{print $3}')"; sleep 2
echo "after the process exits:"; show
launchctl bootout "gui/$U/$L" && echo "bootout by label: ok (the fix: bootout before moving the plist)"
rm -rf "$D"
