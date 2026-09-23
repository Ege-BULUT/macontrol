// Probe for the F-B "after": which directories reached from '/' report DIR_MNTSTATUS_MNTPOINT
// (getattrlist ATTR_DIR_MOUNTSTATUS) and what st_dev/st_ino they have.
// Build: cc -O2 -o /tmp/x mountstatus_probe.c ; run with no args.
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void) {
  const char *p[] = {"/", "/Users", "/System/Volumes/Data", "/System/Volumes/Data/Users",
                     "/System/Volumes/VM", "/System/Volumes/Preboot", "/Volumes", "/private/var", NULL};
  for (int i = 0; p[i]; i++) {
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.dirattr = ATTR_DIR_MOUNTSTATUS;
    struct { uint32_t len; uint32_t mnt; } __attribute__((packed)) buf;
    struct stat st;
    int r = getattrlist(p[i], &al, &buf, sizeof buf, 0);
    stat(p[i], &st);
    printf("%-30s mountpoint=%s dev=%d ino=%llu\n", p[i],
           r ? "ERR" : ((buf.mnt & DIR_MNTSTATUS_MNTPOINT) ? "yes" : "no"), st.st_dev,
           (unsigned long long)st.st_ino);
  }
  return 0;
}
