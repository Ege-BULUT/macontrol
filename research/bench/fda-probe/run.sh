#!/bin/sh
# Manual check: does a Full Disk Access grant reach an already-running app, or only after relaunch?
# Builds a throwaway ad-hoc-signed app (its own TCC identity, not Terminal's), launches it with `open`,
# and logs the probe state once a second. While it runs: System Settings > Privacy & Security >
# Full Disk Access > "+" > add the .app printed below, switch it on, and watch the log.
#   granted  = open() of the per-user TCC.db succeeded
#   denied   = EPERM (TCC)      other = any other errno
# The system-wide /Library/.../TCC.db is also logged: on macOS 26.6 it reads fine WITHOUT FDA (see F-0001).
# Afterwards: tccutil reset SystemPolicyAllFiles local.macontrol.fdaprobe ; rm -rf "$DIR"
set -e
SECS=${1:-180}
DIR=${TMPDIR:-/tmp}/macontrol-fdaprobe
APP="$DIR/FDAProbe.app"
rm -rf "$DIR" && mkdir -p "$APP/Contents/MacOS"
cat > "$DIR/p.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
static const char *st(const char *p){int fd=open(p,O_RDONLY);if(fd>=0){close(fd);return "granted";}return errno==EPERM?"denied":"other";}
int main(int c,char**v){char u[1024];snprintf(u,sizeof u,"%s/Library/Application Support/com.apple.TCC/TCC.db",getenv("HOME"));
 FILE*o=fopen(v[1],"w");int n=atoi(v[2]);setvbuf(o,NULL,_IOLBF,0);
 for(int i=0;i<n;i++){fprintf(o,"t=%3ds user-TCC.db=%s system-TCC.db=%s\n",i,st(u),st("/Library/Application Support/com.apple.TCC/TCC.db"));sleep(1);}
 return 0;}
C
cc -O1 -o "$APP/Contents/MacOS/FDAProbe" "$DIR/p.c"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macontrol.fdaprobe</string>
<key>CFBundleExecutable</key><string>FDAProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
P
codesign -s - --force "$APP" >/dev/null 2>&1
echo "App to add in Full Disk Access: $APP"
: > "$DIR/log"
open -n "$APP" --args "$DIR/log" "$SECS"
tail -f "$DIR/log" & T=$!
sleep "$SECS"; kill $T 2>/dev/null || true
