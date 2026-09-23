// bulkwalk: minimal serial, fd-relative getattrlistbulk walker (a baseline for
// macontrol's engine, not the engine). Prints allocated bytes with hard links
// counted once. -x also asks APFS for ATTR_CMNEXT_PRIVATESIZE|CLONEID|EXT_FLAGS
// (FSOPT_ATTR_CMN_EXTENDED) to measure what that costs, and prints private bytes.
// Build: cc -O2 -o tools/bulkwalk bulkwalk.c     Run: tools/bulkwalk [-x] <dir>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int ext;
static uint64_t alloc_total, private_total, files, dirs, errors;
static char buf[256 * 1024];

// ponytail: open-addressing set of fileids with nlink > 1, fixed 1M slots; grow it if a tree has more hard-linked inodes.
#define SLOTS (1u << 20)
static uint64_t *seen;
static int first_sighting(uint64_t id) {
    for (uint32_t i = (uint32_t)(id * 0x9E3779B97F4A7C15ull >> 44); ; i = (i + 1) & (SLOTS - 1)) {
        if (seen[i] == id) return 0;
        if (seen[i] == 0) { seen[i] = id; return 1; }
    }
}

#define TAKE(dst) (memcpy(&(dst), p, sizeof(dst)), p += sizeof(dst))

static void walk(int dfd) {
    struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID,
        .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
        .forkattr = ext ? ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS : 0 };
    char **sub = NULL; size_t nsub = 0, cap = 0;
    int n;
    while ((n = getattrlistbulk(dfd, &al, buf, sizeof buf, ext ? FSOPT_ATTR_CMN_EXTENDED : 0)) > 0) {
        for (char *e = buf; n--; ) {
            char *p = e; uint32_t len; attribute_set_t ret; attrreference_t name;
            fsobj_type_t type; uint64_t fileid; uint32_t nlink = 1; off_t alloc = 0, priv = 0;
            TAKE(len); TAKE(ret);
            char *namep = p; TAKE(name);
            TAKE(type); TAKE(fileid);
            if (ret.fileattr & ATTR_FILE_LINKCOUNT) TAKE(nlink);
            if (ret.fileattr & ATTR_FILE_ALLOCSIZE) TAKE(alloc);
            if (ret.forkattr & ATTR_CMNEXT_PRIVATESIZE) TAKE(priv);
            e += len;
            if (type == VDIR) {
                if (nsub == cap) sub = realloc(sub, (cap = cap ? cap * 2 : 16) * sizeof *sub);
                sub[nsub++] = strdup(namep + name.attr_dataoffset);
            } else if (nlink < 2 || first_sighting(fileid)) {
                files++; alloc_total += alloc; private_total += priv;
            }
        }
    }
    if (n < 0) errors++;
    for (size_t i = 0; i < nsub; i++) {  // recurse after the listing so one buffer serves every level
        int cfd = openat(dfd, sub[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (cfd < 0) errors++; else { dirs++; walk(cfd); close(cfd); }
        free(sub[i]);
    }
    free(sub);
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "-x")) { ext = 1; argv++; argc--; }
    if (argc != 2) { fprintf(stderr, "usage: bulkwalk [-x] <dir>\n"); return 2; }
    seen = calloc(SLOTS, sizeof *seen);
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY);
    if (fd < 0) { perror(argv[1]); return 1; }
    dirs = 1; walk(fd);
    printf("%llu %s\n", alloc_total, argv[1]);
    if (ext) printf("private_bytes %llu\n", private_total);
    printf("files %llu dirs %llu errors %llu\n", files, dirs, errors);
    return errors ? 1 : 0;
}
