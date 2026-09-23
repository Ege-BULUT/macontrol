// Build: clang -O2 -fobjc-arc -framework Foundation walk.m -o walk
// Run:   ./walk <root> <mode 0|1|2> <max entries>   (T-0015, dive-tencent-lemon-cleaner, 2026-09-23)
// Result on this Mac, /System/Library/Frameworks, 40 904 entries, warm cache, 2 runs each:
//   mode 0 (bulk only) 0.293 / 0.340 s; mode 2 (+ATTR_CMN_FLAGS) 0.301 / 0.290 s; mode 1 (Lemon-style NSURL lookups) 3.806 / 3.944 s
// Bench: getattrlistbulk walk, plain vs + per-entry NSURLIsUbiquitousItemKey lookups
// (mirrors LMFileScanTask.m:191-235 on macOS 13+: shouldSkipICloudFile + qm_isICloudFileAtPath per regular file).
// Mode 0: bulk only. 1: bulk + Lemon-style NSURL lookups. 2: bulk + ATTR_CMN_FLAGS & SF_DATALESS (same syscall).
#import <Foundation/Foundation.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
static long entries = 0, cap = 0, dataless = 0;
static BOOL isUbi(NSString *p){ NSNumber *v=nil; [[NSURL fileURLWithPath:p] getResourceValue:&v forKey:NSURLIsUbiquitousItemKey error:NULL]; return v.boolValue; }
static void walk(NSString *dir, int mode){
  if (entries >= cap) return;
  int fd = open(dir.fileSystemRepresentation, O_RDONLY|O_DIRECTORY); if (fd<0) return;
  struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT;
  al.commonattr = ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_OBJTYPE|(mode==2?ATTR_CMN_FLAGS:0);
  al.fileattr = ATTR_FILE_ALLOCSIZE;
  char buf[64*1024]; NSMutableArray *subs=[NSMutableArray array];
  for(;;){ int n = getattrlistbulk(fd,&al,buf,sizeof buf,0); if(n<=0) break;
    char *e = buf;
    for(int i=0;i<n;i++){ @autoreleasepool{
      char *f=e; uint32_t len=*(uint32_t*)f; e+=len; f+=4; attribute_set_t r=*(attribute_set_t*)f; f+=sizeof r;
      attrreference_t nr=*(attrreference_t*)f; char *name=f+nr.attr_dataoffset; f+=sizeof nr;
      fsobj_type_t t=*(fsobj_type_t*)f; f+=sizeof t;
      uint32_t flags=0; if(mode==2){ flags=*(uint32_t*)f; f+=4; if(flags & SF_DATALESS) dataless++; }
      NSString *full=[dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
      entries++;
      if(mode==1){ if(isUbi(full)) dataless++; if(t==VREG && isUbi(full)) dataless++; }
      if(t==VDIR) [subs addObject:full];
    }}
  }
  close(fd);
  for(NSString *s in subs) walk(s,mode);
}
int main(int argc,const char**argv){ @autoreleasepool{
  NSString *root=[NSString stringWithUTF8String:argv[1]]; int mode=atoi(argv[2]); cap=atol(argv[3]);
  struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a); walk(root,mode); clock_gettime(CLOCK_MONOTONIC,&b);
  printf("mode=%d entries=%ld time=%.3fs flagged=%ld\n",mode,entries,(b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9,dataless);
}}
