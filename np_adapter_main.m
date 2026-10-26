// np_adapter_main.m — exercises the EXACT vendored reader path the sidecar uses:
// internal_get(false) -> the 4-call serial-queue adapter (nowplaying-cli's dylib path).
// Not a hand-written legacy probe. Run in an Aqua Terminal to validate the reader.
#import <Foundation/Foundation.h>
extern NSDictionary *internal_get(BOOL isTestMode);

int main(void) {
    @autoreleasepool {
        NSDictionary *d = internal_get(false);
        if (!d) { printf("NIL — internal_get returned nil\n"); return 2; }
        printf("OK keys=%lu\n", (unsigned long)[d count]);
        for (NSString *k in @[@"title", @"artist", @"album", @"playing",
                              @"elapsedTime", @"duration", @"processIdentifier"]) {
            id v = d[k];
            printf("  %-18s = %s\n", k.UTF8String,
                   v ? [[v description] UTF8String] : "(nil)");
        }
        id art = d[@"artworkData"];
        printf("  artworkData bytes  = %lu\n",
               [art isKindOfClass:[NSData class]] ? (unsigned long)[(NSData *)art length] : 0UL);
        return 0;
    }
}
