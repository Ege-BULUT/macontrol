// Runs PermissionsKit's real FDA check (MPFullDiskAccessAuthorizer.m, compiled from the clone)
// and logs, per probe file, whether it exists and what open(O_RDONLY) returns.
// Built into a throwaway ad-hoc app by run.sh so TCC judges this app, not the terminal.
#import <Foundation/Foundation.h>
#import "MPFullDiskAccessAuthorizer.h"
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static const char *statusName(MPAuthorizationStatus s) {
    switch (s) {
        case MPAuthorizationStatusNotDetermined: return "NotDetermined";
        case MPAuthorizationStatusDenied: return "Denied";
        case MPAuthorizationStatusAuthorized: return "Authorized";
        case MPAuthorizationStatusLimited: return "Limited";
    }
    return "?";
}

int main(int argc, char **argv) {
    @autoreleasepool {
        FILE *o = argc > 1 ? fopen(argv[1], "w") : stdout;
        NSString *h = NSHomeDirectory();
        // The four files of MPFullDiskAccessAuthorizer.m:91-96, in its order, plus the system TCC.db (F-0001).
        NSArray<NSString *> *paths = @[
            [h stringByAppendingPathComponent:@"Library/Safari/CloudTabs.db"],
            [h stringByAppendingPathComponent:@"Library/Safari/Bookmarks.plist"],
            [h stringByAppendingPathComponent:@"Library/Application Support/com.apple.TCC/TCC.db"],
            @"/Library/Preferences/com.apple.TimeMachine.plist",
            @"/Library/Application Support/com.apple.TCC/TCC.db",
        ];
        for (NSString *p in paths) {
            struct stat sb;
            const char *exists = stat(p.fileSystemRepresentation, &sb) == 0 ? "yes" : strerror(errno);
            int fd = open(p.fileSystemRepresentation, O_RDONLY);
            int e = errno;
            char buf[16] = {0};
            ssize_t n = fd >= 0 ? read(fd, buf, sizeof buf - 1) : -1;
            if (fd >= 0) close(fd);
            fprintf(o, "%-58s stat=%-26s open=%s%s\n",
                    [[p stringByAbbreviatingWithTildeInPath] UTF8String], exists,
                    fd >= 0 ? "ok" : strerror(e),
                    fd >= 0 ? [[NSString stringWithFormat:@" (read %zd B)", n] UTF8String] : "");
        }
        MPAuthorizationStatus s = [[MPFullDiskAccessAuthorizer new] authorizationStatus];
        fprintf(o, "PermissionsKit MPFullDiskAccessAuthorizer.authorizationStatus = %s\n", statusName(s));
        if (o != stdout) fclose(o);
    }
    return 0;
}
