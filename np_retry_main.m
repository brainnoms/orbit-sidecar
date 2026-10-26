// np_retry_main.m — static link (like the daemon), but call internal_get in a
// retry loop instead of once at t=0. Tests the "connection not ready yet at
// launch" hypothesis WITHOUT perl, WITHOUT a GUI session.
#import <Foundation/Foundation.h>
extern NSDictionary *internal_get(BOOL isTestMode);

int main(void) {
    @autoreleasepool {
        for (int i = 1; i <= 12; i++) {
            NSDictionary *d = internal_get(false);
            if (d) {
                printf("HIT on attempt %d: title=%s playing=%s\n", i,
                       [[(d[@"title"] ?: @"-") description] UTF8String],
                       [[(d[@"playing"] ?: @"-") description] UTF8String]);
                return 0;
            }
            usleep(500000); // 0.5s
        }
        printf("NIL after 12 tries over ~6s\n");
        return 2;
    }
}
