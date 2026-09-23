// btm_probe.m: counts what KnockKnock's BTM plugin shows vs drops, on this Mac.
// Links KnockKnock's prebuilt libDumpBTM.a (GPL-3.0, study only; not copied here) from the clone:
//   research/sources/objective-see-knockknock/Libraries/BTM/ (objective-see/KnockKnock@914f2c0)
// Mirrors the filters in Plugins/BTM.m:97 (disposition & 0x1), :105 (embeddedIDs),
// :113-119 (executablePath is a string) and Results/File.m:59-75 (path must exist, else nil).
// Prints counts only, never paths or bundle IDs. Read-only: parses the .btm file, writes nothing.
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import "dumpBTM.h"

int main(void) {
    @autoreleasepool {
        NSDictionary *c = parseBTM(nil);
        long err = [c[KEY_BTM_ERROR] longValue];
        printf("parseBTM error=%ld (0 = ok)\n", err);
        if (err) return 1;
        long total = 0, disabled = 0, parents = 0, noExe = 0, shown = 0, orphanEnabled = 0,
             orphanDisabled = 0, withBundleID = 0, withTeamID = 0, withAssoc = 0, orphanWithBundle = 0;
        NSMutableDictionary<NSString *, NSNumber *> *orphanTypes = [NSMutableDictionary dictionary], *noExeTypes = [NSMutableDictionary dictionary];
        for (NSString *uuid in c[KEY_BTM_ITEMS_BY_USER_ID]) {
            for (NSDictionary *item in c[KEY_BTM_ITEMS_BY_USER_ID][uuid]) {
                total++;
                if ([item[KEY_BTM_ITEM_BUNDLE_ID] isKindOfClass:NSString.class]) withBundleID++;
                if ([item[KEY_BTM_ITEM_TEAM_ID] isKindOfClass:NSString.class]) withTeamID++;
                if ([item[KEY_BTM_ITEM_ASSOCIATED_IDS] isKindOfClass:NSArray.class] &&
                    [item[KEY_BTM_ITEM_ASSOCIATED_IDS] count]) withAssoc++;
                BOOL enabled = ([item[KEY_BTM_ITEM_DISPOSITION] longValue] & 0x1) != 0;
                if (item[KEY_BTM_ITEM_EMBEDDED_IDS] != nil) { parents++; continue; }
                NSString *exe = item[KEY_BTM_ITEM_EXE_PATH];
                if (![exe isKindOfClass:NSString.class]) {
                    noExe++; if (!enabled) disabled++;
                    id u = item[KEY_BTM_ITEM_URL];
                    NSURL *url = [u isKindOfClass:NSURL.class] ? u : ([u isKindOfClass:NSString.class] ? [NSURL URLWithString:u] : nil);
                    struct stat ust;
                    BOOL urlExists = url.isFileURL && stat(url.fileSystemRepresentation, &ust) == 0;
                    NSArray *pc = url.path.pathComponents;
                    NSString *top = pc.count > 2 ? [NSString stringWithFormat:@"/%@/%@", pc[1], ([pc[1] isEqual:@"Users"] || [pc[1] isEqual:@"Applications"]) ? @"<name>" : pc[2]] : (url.path ?: @"-");
                    NSString *t = [NSString stringWithFormat:@"%@type=%#lx under=%@ ext=%@ | enabled=%d url=%s urlExists=%d",
                                   [item[KEY_BTM_ITEM_TYPE_DETAILS] description] ?: @"?", [item[KEY_BTM_ITEM_TYPE] longValue], top, url.pathExtension, enabled,
                                   url ? (url.isFileURL ? "file" : "other") : "none", urlExists];
                    noExeTypes[t] = @(noExeTypes[t].integerValue + 1);
                    continue;
                }
                struct stat st;
                BOOL exists = stat(exe.fileSystemRepresentation, &st) == 0;
                if (!enabled) { disabled++; if (!exists) orphanDisabled++; }
                else if (!exists) orphanEnabled++;
                else shown++;
                if (!exists) {
                    NSString *pl = [item[KEY_BTM_ITEM_PLIST_PATH] isKindOfClass:NSString.class] ? item[KEY_BTM_ITEM_PLIST_PATH] : nil;
                    struct stat pst;
                    NSString *plDir = pl ? [[pl stringByDeletingLastPathComponent] stringByAbbreviatingWithTildeInPath] : @"-";
                    NSString *t = [NSString stringWithFormat:@"%@ plistDir=%@ plistExists=%d teamID=%d exeAbs=%d exeTop=%@", [item[KEY_BTM_ITEM_TYPE_DETAILS] description] ?: @"?",
                                   plDir, pl ? stat(pl.fileSystemRepresentation, &pst) == 0 : -1, [item[KEY_BTM_ITEM_TEAM_ID] isKindOfClass:NSString.class], [exe hasPrefix:@"/"],
                                   exe.pathComponents.count > 2 ? ([exe.pathComponents[1] isEqual:@"Users"] ? @"/Users/<user>" : [NSString stringWithFormat:@"/%@", exe.pathComponents[1]]) : @"?"];
                    // resolve a bundle-relative path against the parent record's url (what BTM.m never does)
                    NSDictionary *parent = nil;
                    for (NSDictionary *o in c[KEY_BTM_ITEMS_BY_USER_ID][uuid])
                        if ([o[KEY_BTM_ITEM_ID] isEqual:item[KEY_BTM_ITEM_PARENT_ID]]) { parent = o; break; }
                    NSString *base = [parent[KEY_BTM_ITEM_URL] isKindOfClass:NSURL.class] ? [parent[KEY_BTM_ITEM_URL] path] : nil;
                    struct stat rst;
                    int exeViaParent = base ? stat([base stringByAppendingPathComponent:exe].fileSystemRepresentation, &rst) == 0 : -1;
                    int plistViaParent = (base && pl) ? stat([base stringByAppendingPathComponent:pl].fileSystemRepresentation, &rst) == 0 : -1;
                    t = [t stringByAppendingFormat:@" parentFound=%d exeViaParent=%d plistViaParent=%d parentEnabled=%ld",
                         parent != nil, exeViaParent, plistViaParent, [parent[KEY_BTM_ITEM_DISPOSITION] longValue] & 0x1];
                    // is the job loaded in launchd right now? (launchctl print exit 0 = loaded)
                    NSString *label = (base && pl) ? [NSDictionary dictionaryWithContentsOfFile:[base stringByAppendingPathComponent:pl]][@"Label"] : nil;
                    if ([label isKindOfClass:NSString.class]) {
                        NSTask *task = [NSTask new];
                        task.launchPath = @"/bin/launchctl";
                        task.arguments = @[@"print", [NSString stringWithFormat:@"gui/%u/%@", getuid(), label]];
                        task.standardOutput = task.standardError = [NSFileHandle fileHandleWithNullDevice];
                        [task launch]; [task waitUntilExit];
                        t = [t stringByAppendingFormat:@" loadedInGuiDomain=%d", task.terminationStatus == 0];
                    }
                    orphanTypes[t] = @(orphanTypes[t].integerValue + 1);
                    if ([item[KEY_BTM_ITEM_BUNDLE_ID] isKindOfClass:NSString.class]) orphanWithBundle++;
                }
            }
        }
        printf("records total=%ld\n", total);
        printf("  parents (embeddedIDs, skipped BTM.m:105)=%ld\n", parents);
        printf("  no executablePath (skipped BTM.m:113-119)=%ld\n", noExe);
        printf("  disabled (skipped BTM.m:97)=%ld  of which exe missing=%ld\n", disabled, orphanDisabled);
        printf("  enabled but exe missing (dropped File.m:59-75)=%ld\n", orphanEnabled);
        printf("  enabled + exe exists (KnockKnock can show, before dedup)=%ld\n", shown);
        printf("records carrying bundleID=%ld teamID=%ld associatedBundleIDs=%ld (BTM.m reads none of them)\n",
               withBundleID, withTeamID, withAssoc);
        printf("exe-missing records that still carry a bundleID=%ld\n", orphanWithBundle);
        for (NSString *t in noExeTypes) printf("  no-exe typeDetails '%s' x%ld\n", t.UTF8String, noExeTypes[t].longValue);
        for (NSString *t in orphanTypes) printf("  exe-missing typeDetails '%s' x%ld\n", t.UTF8String, orphanTypes[t].longValue);
    }
    return 0;
}
