// getattrlistbulk probe: per entry logical/allocated size, link count, inode,
// and the APFS extended attrs (private size, clone id, clone refcount, ext flags).
// Build: cc -O2 -o bulk bulk.c   Run: ./bulk <dir>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int dfd = open(argc > 1 ? argv[1] : ".", O_RDONLY | O_DIRECTORY);
    if (dfd < 0) { perror("open"); return 1; }
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
    al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    al.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID |
                  ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT;
    char buf[64 * 1024];
    int n;
    printf("%-13s %11s %11s %11s %5s %10s %18s %6s %s\n", "name", "logical",
           "alloc", "private", "nlink", "fileid", "cloneid", "clrefs", "extflags");
    while ((n = getattrlistbulk(dfd, &al, buf, sizeof buf, FSOPT_ATTR_CMN_EXTENDED)) > 0) {
        char *e = buf;
        for (int i = 0; i < n; i++) {
            char *p = e;
            uint32_t len = *(uint32_t *)p; p += 4;
            attribute_set_t ret = *(attribute_set_t *)p; p += sizeof(attribute_set_t);
            attrreference_t nameref = *(attrreference_t *)p;
            const char *name = p + nameref.attr_dataoffset; p += sizeof(attrreference_t);
            fsobj_type_t type = *(fsobj_type_t *)p; p += sizeof(fsobj_type_t);
            uint32_t flags = *(uint32_t *)p; p += 4;
            uint64_t fileid = *(uint64_t *)p; p += 8;
            uint32_t nlink = 0; off_t total = 0, alloc = 0, priv = -1;
            uint64_t cloneid = 0, ext = 0; uint32_t refs = 0;
            // Attributes come back in bit order: file attrs, then forkattr (CMNEXT).
            if (ret.fileattr & ATTR_FILE_LINKCOUNT) { nlink = *(uint32_t *)p; p += 4; }
            if (ret.fileattr & ATTR_FILE_TOTALSIZE) { total = *(off_t *)p; p += 8; }
            if (ret.fileattr & ATTR_FILE_ALLOCSIZE) { alloc = *(off_t *)p; p += 8; }
            if (ret.forkattr & ATTR_CMNEXT_PRIVATESIZE) { priv = *(off_t *)p; p += 8; }
            if (ret.forkattr & ATTR_CMNEXT_CLONEID) { cloneid = *(uint64_t *)p; p += 8; }
            if (ret.forkattr & ATTR_CMNEXT_EXT_FLAGS) { ext = *(uint64_t *)p; p += 8; }
            if (ret.forkattr & ATTR_CMNEXT_CLONE_REFCNT) { refs = *(uint32_t *)p; p += 4; }
            if (type == VREG)
                printf("%-13s %11lld %11lld %11lld %5u %10llu %18llx %6u 0x%llx%s%s%s%s\n",
                       name, total, alloc, priv, nlink, fileid, cloneid, refs, ext,
                       (ext & EF_MAY_SHARE_BLOCKS) ? " MAY_SHARE" : "",
                       (ext & EF_SHARES_ALL_BLOCKS) ? " SHARES_ALL" : "",
                       (ext & EF_IS_SPARSE) ? " SPARSE" : "",
                       (flags & UF_COMPRESSED) ? " [UF_COMPRESSED]" : "");
            else if (type == VDIR && (flags & SF_FIRMLINK))
                printf("%-13s dir flags=0x%x SF_FIRMLINK\n", name, flags);
            e += len;
        }
    }
    if (n < 0) perror("getattrlistbulk");
    close(dfd);
    return 0;
}
