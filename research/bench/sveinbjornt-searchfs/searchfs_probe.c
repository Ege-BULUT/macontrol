// searchfs_probe: counts what a searchfs(2) name search really costs and how often it
// restarts. Same call shape as sveinbjornt/searchfs@3afcfc3 main.m:272-423 (ATTR_CMN_NAME
// search, FSID|OBJID return, 1 s timelimit), but counts instead of printing:
// calls, EAGAIN, EBUSY restarts, raw matches vs unique objects, fsgetpath failures.
// -F returns ATTR_CMN_FILEID (64-bit) instead of OBJID, to test whether APFS vends it.
// -w <path> creates and unlinks <path> between every resumed call: a deterministic catalog change.
// Build: cc -O2 -o searchfs_probe searchfs_probe.c
// Run:   ./searchfs_probe [-e] [-F] [-p] [-m maxmatches] [-r maxrestarts] [-w path] <volume> <name>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

struct name_param { uint32_t size; attrreference_t ref; char name[NAME_MAX * 3 + 1]; };
struct empty_param { uint32_t size; attrreference_t ref; };

// ponytail: fixed 4M-slot open-addressing set of (fsid,obj) keys; grow it for volumes with more matches.
#define SLOTS (1u << 22)
static uint64_t *seen;
static int first(uint64_t id) {
    id |= 1ull << 63; // never 0
    for (uint32_t i = (uint32_t)(id * 0x9E3779B97F4A7C15ull >> 42) & (SLOTS - 1); ; i = (i + 1) & (SLOTS - 1)) {
        if (seen[i] == id) return 0;
        if (!seen[i]) { seen[i] = id; return 1; }
    }
}

static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }

int main(int argc, char **argv) {
    int exact = 0, fileid = 0, print = 0, ch; unsigned maxm = 20, maxrestarts = 5; const char *wpath = NULL;
    while ((ch = getopt(argc, argv, "eFpm:r:w:")) != -1) switch (ch) {
        case 'e': exact = 1; break;
        case 'F': fileid = 1; break;
        case 'p': print = 1; break;
        case 'm': maxm = (unsigned)atoi(optarg); break;
        case 'r': maxrestarts = (unsigned)atoi(optarg); break;
        case 'w': wpath = optarg; break;
        default: return 64;
    }
    if (argc - optind != 2) { fprintf(stderr, "usage: searchfs_probe [-e] [-F] [-p] [-m n] [-r n] <volume> <name>\n"); return 64; }
    const char *vol = argv[optind], *term = argv[optind + 1];
    size_t tl = strlen(term);
    if (tl == 0 || tl > NAME_MAX * 3) { fprintf(stderr, "bad term length %zu\n", tl); return 64; }
    seen = calloc(SLOTS, sizeof *seen);

    struct name_param p1 = { 0 }; struct empty_param p2 = { 0 };
    memcpy(p1.name, term, tl + 1);
    p1.ref.attr_dataoffset = sizeof(attrreference_t);
    p1.ref.attr_length = (uint32_t)tl + 1;
    p1.size = sizeof(attrreference_t) + p1.ref.attr_length;
    p2.size = sizeof(attrreference_t); p2.ref.attr_dataoffset = sizeof(attrreference_t);

    struct attrlist ret = { .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_FSID | (fileid ? ATTR_CMN_FILEID : ATTR_CMN_OBJID) };
    size_t recsz = 4 + sizeof(fsid_t) + (fileid ? 8 : sizeof(fsobj_id_t));
    size_t bufsz = maxm * (recsz + 8);
    char *buf = malloc(bufsz);
    struct fssearchblock sb = { 0 };
    sb.returnattrs = &ret; sb.returnbuffer = buf; sb.returnbuffersize = bufsz;
    sb.maxmatches = maxm; sb.timelimit.tv_sec = 1;
    sb.searchparams1 = &p1; sb.sizeofsearchparams1 = p1.size + sizeof(uint32_t);
    sb.searchparams2 = &p2; sb.sizeofsearchparams2 = sizeof p2;
    sb.searchattrs.bitmapcount = ATTR_BIT_MAP_COUNT; sb.searchattrs.commonattr = ATTR_CMN_NAME;
    unsigned base = SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS | (exact ? 0 : SRCHFS_MATCHPARTIALNAMES);

    unsigned long calls = 0, eagain = 0, restarts = 0, raw = 0, uniq = 0, nopath = 0;
    struct searchstate st; int err; double t0 = now();
    unsigned opts = base | SRCHFS_START;
    for (;;) {
        unsigned long n = 0;
        err = searchfs(vol, &sb, &n, 0, opts, &st) == -1 ? errno : 0;
        calls++;
        if (err == 0 || err == EAGAIN) {
            char *p = buf;
            for (unsigned long i = 0; i < n; i++) {
                uint32_t len; fsid_t fs; uint64_t obj;
                memcpy(&len, p, 4); memcpy(&fs, p + 4, sizeof fs);
                if (fileid) memcpy(&obj, p + 4 + sizeof fs, 8);
                else { fsobj_id_t o; memcpy(&o, p + 4 + sizeof fs, sizeof o); obj = (uint64_t)o.fid_objno | ((uint64_t)o.fid_generation << 32); }
                raw++;
                if (first(obj ^ ((uint64_t)(uint32_t)fs.val[0] << 40))) uniq++;
                char path[PATH_MAX];
                if (fsgetpath(path, sizeof path, &fs, obj) < 0) nopath++;
                else if (print) printf("%s\n", path);
                p += len;
            }
        }
        if (err == EAGAIN) { eagain++; opts = base; if (wpath) { close(open(wpath, O_CREAT | O_WRONLY, 0644)); unlink(wpath); } continue; }
        if (err == EBUSY && restarts < maxrestarts) { restarts++; opts = base | SRCHFS_START; continue; }
        break;
    }
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    fprintf(stderr, "vol=%s term=%s exact=%d fileid=%d maxmatches=%u final_err=%d(%s) wall=%.2fs sys=%.2fs user=%.2fs "
        "calls=%lu eagain=%lu ebusy_restarts=%lu raw_matches=%lu unique=%lu fsgetpath_fail=%lu\n",
        vol, term, exact, fileid, maxm, err, err ? strerror(err) : "complete", now() - t0,
        ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6, ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6,
        calls, eagain, restarts, raw, uniq, nopath);
    return err ? 1 : 0;
}
