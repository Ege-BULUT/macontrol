// macontrol probe (our code, not GPL source): builds a GrandPerspective tree of N nested
// folders with GP's own model classes and lays it out with GP's own TreeLayoutBuilder, either on
// the main thread (8 MiB stack) or on a plain NSThread (512 KiB default, same as GP's
// AsynchronousTaskManager uses for drawing, scanning, filtering). Exit 0 = survived.
#import <Cocoa/Cocoa.h>
#import "DirectoryItem.h"
#import "PlainFileItem.h"
#import "TreeLayoutBuilder.h"
#import "TreeLayoutTraverser.h"
#import "CompoundItem.h"

NSString *FileSizeUnitSystemKey = @"fileSizeUnitSystem";

@interface CountingTraverser : NSObject <TreeLayoutTraverser> { @public long visits; int maxDepth; }
@end
@implementation CountingTraverser
- (BOOL) descendIntoItem:(Item *)item atRect:(NSRect)rect depth:(int)depth {
  visits++; if (depth > maxDepth) maxDepth = depth; return YES;  // like TreeDrawerBase with unlimited display depth
}
- (void) emergedFromItem:(Item *)item {}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    int depth = atoi(argv[1]);
    BOOL onThread = argc > 2 && strcmp(argv[2], "thread") == 0;
    if (argc > 3 && strcmp(argv[3], "wide") == 0) {
      // One folder with `depth` sub-folders, still in the unbalanced linked-list form that
      // addSubdir: builds (as TreeRefresher's shallow rescan visits collector.directoryItems).
      DirectoryItem *p = [[DirectoryItem alloc] initWithLabel: @"p" parent: nil flags: 0
                                                 creationTime: 0 modificationTime: 0 accessTime: 0];
      for (int i = 0; i < depth; i++) {
        DirectoryItem *c = [[DirectoryItem alloc] initWithLabel: @"c" parent: p flags: 0
                                                   creationTime: 0 modificationTime: 0 accessTime: 0];
        [p addSubdir: c]; [c release];
      }
      __block long n = 0;
      void (^visit)(void) = ^{ [CompoundItem visitFileItemChildrenMaybeNil: p.directoryItems
                                                                   callback: ^(FileItem *x) { n++; }]; };
      if (onThread) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSThread *th = [[NSThread alloc] initWithBlock: ^{ visit(); dispatch_semaphore_signal(done); }];
        [th start]; dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      } else visit();
      printf("wide=%d visited=%ld OK\n", depth, n);
      return 0;
    }
    NSMutableArray *chain = [NSMutableArray array];
    DirectoryItem *d = nil;
    for (int i = 0; i <= depth; i++) {
      DirectoryItem *c = [[DirectoryItem alloc] initWithLabel: @"d" parent: d flags: 0
                                                 creationTime: 0 modificationTime: 0 accessTime: 0];
      [chain addObject: c]; [c release]; d = c;
    }
    PlainFileItem *f = [[PlainFileItem alloc] initWithLabel: @"f" parent: d size: 1000 type: nil
                                                      flags: 0 creationTime: 0 modificationTime: 0 accessTime: 0];
    [d addFile: f]; [f release];
    for (NSInteger i = chain.count - 1; i >= 0; i--) {   // finalize bottom-up, as TreeBuilder's unwind does
      [chain[i] setSize];
      if (i > 0) [chain[i - 1] addSubdir: chain[i]];
    }
    TreeLayoutBuilder *lb = [[TreeLayoutBuilder alloc] init];
    CountingTraverser *t = [[CountingTraverser alloc] init];
    void (^run)(void) = ^{ [lb layoutItemTree: chain[0] inRect: NSMakeRect(0, 0, 1168, 688) traverser: t]; };
    if (onThread) {
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      NSThread *th = [[NSThread alloc] initWithBlock: ^{ run(); dispatch_semaphore_signal(done); }];
      printf("thread stackSize=%lu\n", (unsigned long)th.stackSize);
      [th start];
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    } else {
      run();
    }
    printf("depth=%d visits=%ld maxDepth=%d OK\n", depth, t->visits, t->maxDepth);
  }
  return 0;
}
