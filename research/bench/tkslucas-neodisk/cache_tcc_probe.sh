#!/bin/sh
# F-0045: does a same-user app WITHOUT Full Disk Access read a scan cache in ~/Library/Application Support?
# Neodisk writes its snapshots to ~/Library/Application Support/Neodisk/ScanCache (0644, LZFSE, no crypto).
# This builds an ad-hoc-signed .app (its own TCC identity, not Terminal's), writes a canary cache file,
# launches the app with `open`, and has it read the canary plus ~/Library/Safari (FDA-only control).
# Expected: canary readable, Safari -> errno 1 (EPERM). Cleans up the canary afterwards.
set -e
W=$(mktemp -d); APP="$W/P.app"; mkdir -p "$APP/Contents/MacOS"
CAN="$HOME/Library/Application Support/macontrol-neodisk-probe"; mkdir -p "$CAN"
printf 'Mail/V10/INBOX.mbox/Attachments/secret-contract.pdf\n' > "$CAN/canary.ndscan"
cat > "$W/p.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
static void t(FILE*o,const char*p){int fd=open(p,O_RDONLY);if(fd<0){fprintf(o,"%s -> errno %d (%s)\n",p,errno,strerror(errno));return;}char b[128]={0};ssize_t n=read(fd,b,sizeof b-1);close(fd);fprintf(o,"%s -> read %zd bytes: %s",p,n,n>0?b:"\n");}
int main(int c,char**v){FILE*o=fopen(v[1],"w");char a[1024],s[1024];const char*h=getenv("HOME");
snprintf(a,sizeof a,"%s/Library/Application Support/macontrol-neodisk-probe/canary.ndscan",h);
snprintf(s,sizeof s,"%s/Library/Safari",h);t(o,a);t(o,s);fclose(o);return 0;}
C
cc -O1 -o "$APP/Contents/MacOS/P" "$W/p.c"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macontrol.neodiskcacheprobe</string>
<key>CFBundleExecutable</key><string>P</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
P
codesign -s - --force "$APP" >/dev/null 2>&1
open -W -n "$APP" --args "$W/out.txt"; cat "$W/out.txt"
/bin/rm -rf "$CAN" "$W"
