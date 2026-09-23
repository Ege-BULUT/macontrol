// macontrol probe (our code): mirrors a real folder into GrandPerspective's own tree classes
// (fts, FTS_PHYSICAL|FTS_XDEV, st_blocks*512 like GP's default "physical" measure, hard links
// once, zero-byte files skipped), balances every folder with GP's TreeBalancer, then lays the
// tree out with GP's TreeLayoutBuilder at the view size in points (what GP rasterizes) and at
// 2x (native Retina pixels). Prints how many files get a tile in each case.
#import <Cocoa/Cocoa.h>
#include <fts.h>
#import "DirectoryItem.h"
#import "PlainFileItem.h"
#import "CompoundItem.h"
#import "TreeBalancer.h"
#import "TreeLayoutBuilder.h"
#import "TreeLayoutTraverser.h"

NSString *FileSizeUnitSystemKey = @"fileSizeUnitSystem";

@interface LeafCounter : NSObject <TreeLayoutTraverser> { @public long files; item_size_t bytes; }
@end
@implementation LeafCounter
- (BOOL) descendIntoItem:(Item *)item atRect:(NSRect)rect depth:(int)depth {
  if (!item.isVirtual && !((FileItem *)item).isDirectory) { files++; bytes += item.itemSize; return NO; }
  return YES;
}
- (void) emergedFromItem:(Item *)item {}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    char *paths[] = { argv[1], NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_XDEV, NULL);
    // Same stack discipline as GP's TreeBuilder: unwind to the entry's parent (fts_parent), so
    // unreadable folders (FTS_DNR, no FTS_DP) cannot unbalance the stack.
    NSMutableArray *stack = [NSMutableArray array];
    NSMutableArray *ents = [NSMutableArray array];
    NSMutableSet *seenLinks = [NSMutableSet set];
    TreeBalancer *tb = [[TreeBalancer alloc] init];
    DirectoryItem *root = nil; long nFiles = 0; item_size_t total = 0;
    void (^pop)(void) = ^{
      DirectoryItem *d = [stack.lastObject retain]; [stack removeLastObject]; [ents removeLastObject];
      [d setSize]; [d balanceTree: tb];
      if (stack.count) [(DirectoryItem *)stack.lastObject addSubdir: d];
      [d release];
    };
    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
      if (e->fts_info == FTS_DP || e->fts_info == FTS_DNR || e->fts_info == FTS_ERR
          || e->fts_info == FTS_NS || e->fts_info == FTS_DC) continue;
      while (ents.count && [ents.lastObject pointerValue] != e->fts_parent) pop();
      NSString *name = [NSString stringWithUTF8String: e->fts_name] ?: @"?";
      if (S_ISDIR(e->fts_statp->st_mode)) {
        DirectoryItem *d = [[DirectoryItem alloc] initWithLabel: name parent: stack.lastObject flags: 0
                                                   creationTime: 0 modificationTime: 0 accessTime: 0];
        if (!root) root = [d retain];
        [stack addObject: d]; [ents addObject: [NSValue valueWithPointer: e]]; [d release];
      } else {
        if (e->fts_statp->st_nlink > 1) {
          NSNumber *ino = @(e->fts_statp->st_ino);
          if ([seenLinks containsObject: ino]) continue;
          [seenLinks addObject: ino];
        }
        item_size_t sz = (item_size_t)e->fts_statp->st_blocks * 512;
        if (sz == 0 || !stack.count) continue;
        PlainFileItem *f = [[PlainFileItem alloc] initWithLabel: name parent: stack.lastObject size: sz type: nil
                                                          flags: 0 creationTime: 0 modificationTime: 0 accessTime: 0];
        [(DirectoryItem *)stack.lastObject addFile: f]; [f release];
        nFiles++; total += sz;
      }
    }
    while (stack.count) pop();
    fts_close(fts);
    TreeLayoutBuilder *lb = [[TreeLayoutBuilder alloc] init];
    double w = atof(argv[2]), h = atof(argv[3]);
    for (int s = 1; s <= 2; s++) {
      LeafCounter *c = [[LeafCounter alloc] init];
      [lb layoutItemTree: root inRect: NSMakeRect(0, 0, w * s, h * s) traverser: c];
      printf("scale %dx (%gx%g px): %ld of %ld files get a tile (%.1f%%), %.1f%% of bytes\n",
             s, w * s, h * s, c->files, nFiles, 100.0 * c->files / nFiles, 100.0 * c->bytes / total);
    }
  }
  return 0;
}
