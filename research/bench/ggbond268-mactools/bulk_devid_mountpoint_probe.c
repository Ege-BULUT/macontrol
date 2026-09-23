#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
/* For each directory entry of argv[1]: devid reported by getattrlistbulk vs lstat of the child path. */
int main(int argc, char **argv) {
  struct attrlist al = {0};
  al.bitmapcount = ATTR_BIT_MAP_COUNT;
  al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE;
  int fd = open(argv[1], O_RDONLY | O_DIRECTORY);
  struct stat ps; fstat(fd, &ps);
  char buf[65536]; int n;
  while ((n = getattrlistbulk(fd, &al, buf, sizeof buf, 0)) > 0) {
    char *p = buf;
    for (int i = 0; i < n; i++) {
      uint32_t len = *(uint32_t *)p; char *c = p + 4 + sizeof(attribute_set_t);
      attrreference_t *nr = (attrreference_t *)c; char *name = (char *)nr + nr->attr_dataoffset; c += sizeof(attrreference_t);
      dev_t dev = *(dev_t *)c; c += sizeof(dev_t); fsobj_type_t t = *(fsobj_type_t *)c;
      if (t == VDIR) {
        char path[2048]; snprintf(path, sizeof path, "%s/%s", argv[1], name);
        struct stat cs; int r = lstat(path, &cs);
        printf("%-28s bulk_devid=%d lstat_dev=%d parent_dev=%d %s\n", name, dev, r == 0 ? cs.st_dev : -1, ps.st_dev,
               (r == 0 && cs.st_dev != dev) ? "<- MOUNT POINT MISSED BY BULK DEVID" : "");
      }
      p += len;
    }
  }
  return 0;
}
