#include <dlfcn.h>
#import <Foundation/Foundation.h>
typedef void *(*GetFn)(unsigned char);
int main(void){ @autoreleasepool{
  void *h = dlopen("/Users/minowicz/.hermes/profiles/donna/cache/scratch/libMRMini_test.dylib", RTLD_NOW | RTLD_GLOBAL);
  if(!h){ printf("dlopen fail: %s\n", dlerror()); return 3; }
  GetFn g = (GetFn)dlsym(h, "internal_get");
  if(!g){ printf("internal_get not found\n"); return 4; }
  void *d = g(0);
  if(!d){ printf("NIL\n"); return 2; }
  NSDictionary *dict = (__bridge NSDictionary *)d;
  printf("HIT title=%s playing=%s\n",
     [[(dict[@"title"]?:@"-") description] UTF8String],
     [[(dict[@"playing"]?:@"-") description] UTF8String]);
  return 0;
}}