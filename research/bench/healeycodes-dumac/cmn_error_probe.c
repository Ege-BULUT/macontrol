// macontrol probe (own code, no dumac code): does getattrlistbulk emit per-entry
// ATTR_CMN_ERROR entries, and where does the error word sit relative to the
// ATTR_CMN_NAME attrreference? man getattrlistbulk(2) says ERROR comes right after
// ATTR_CMN_RETURNED_ATTRS. healeycodes/dumac src/main.rs:261-294 reads NAME first.
//
// Provokes errors by racing /dev/fd (fdesc, readdir-emulated bulk path): a second
// thread opens and closes fds while the main thread lists the directory.
// Build: cc -O2 -o /tmp/cmn_error_probe cmn_error_probe.c -lpthread ; run: ./cmn_error_probe [seconds]
#include <sys/attr.h>
#include <sys/vnode.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static atomic_int stop;

static void *churn(void *arg) {
    (void)arg;
    int fds[64];
    while (!atomic_load(&stop)) {
        for (int i = 0; i < 64; i++) fds[i] = dup(2);
        for (int i = 0; i < 64; i++) if (fds[i] >= 0) close(fds[i]);
    }
    return NULL;
}

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 5;
    pthread_t t;
    pthread_create(&t, NULL, churn, NULL);
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR |
                    ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    al.fileattr = ATTR_FILE_ALLOCSIZE;
    static char buf[16 * 1024];
    long entries = 0, err_entries = 0, printed = 0;
    time_t end = time(NULL) + secs;
    while (time(NULL) < end) {
        int dfd = open("/dev/fd", O_RDONLY | O_DIRECTORY);
        if (dfd < 0) { perror("open /dev/fd"); break; }
        int n;
        while ((n = getattrlistbulk(dfd, &al, buf, sizeof buf, 0)) > 0) {
            char *e = buf;
            for (int i = 0; i < n; i++) {
                uint32_t len = *(uint32_t *)e;
                char *f = e + sizeof(uint32_t);
                attribute_set_t ret = *(attribute_set_t *)f;
                f += sizeof(attribute_set_t);
                entries++;
                if (ret.commonattr & ATTR_CMN_ERROR) {
                    err_entries++;
                    if (printed < 3) {
                        printed++;
                        // Documented order: ERROR word, then NAME attrreference.
                        uint32_t doc_err = *(uint32_t *)f;
                        attrreference_t doc_ref = *(attrreference_t *)(f + 4);
                        const char *doc_name = (ret.commonattr & ATTR_CMN_NAME)
                            ? (f + 4 + doc_ref.attr_dataoffset) : "(no name)";
                        // dumac's order: NAME attrreference first, then ERROR word.
                        attrreference_t dm_ref = *(attrreference_t *)f;
                        uint32_t dm_err = *(uint32_t *)(f + sizeof(attrreference_t));
                        printf("error entry: len=%u returned.common=0x%08x\n", len, ret.commonattr);
                        printf("  documented order: error=%u name=\"%s\" (ref off=%d len=%u)\n",
                               doc_err, doc_name, doc_ref.attr_dataoffset, doc_ref.attr_length);
                        printf("  dumac order     : error=%u, name ref off=%d len=%u (reads %u bytes at +%d)\n",
                               dm_err, dm_ref.attr_dataoffset, dm_ref.attr_length,
                               dm_ref.attr_length ? dm_ref.attr_length - 1 : 0, dm_ref.attr_dataoffset);
                    }
                }
                e += len;
            }
        }
        close(dfd);
    }
    atomic_store(&stop, 1);
    pthread_join(t, NULL);
    printf("entries=%ld error_entries=%ld\n", entries, err_entries);
    return 0;
}
