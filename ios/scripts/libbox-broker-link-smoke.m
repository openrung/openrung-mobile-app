#import <Foundation/Foundation.h>
#import <Libbox/Libbox.h>

// Build-only executable used by build-libbox-release.sh. It is linked but never
// run; calling native constructors ensures Libbox's static Go archive, punch
// bridge, and resolver references are actually pulled into both Apple slice
// link checks.
int main(void) {
  @autoreleasepool {
    id<LibboxOpenRungBrokerOperation> operation =
        LibboxNewOpenRungBrokerOperationForIOS(@"link-smoke", @"build");
    [operation close];
    id<LibboxOpenRungBrokerOperation> reactNativeOperation =
        LibboxNewOpenRungBrokerOperationForReactNative(@"link-smoke", @"ios");
    [reactNativeOperation close];
    LibboxOpenRungPunchClient *punchClient =
        LibboxNewOpenRungPunchClientForIOS(@"https://coordinator.invalid",
                                          @"relay-link-smoke", NO, @"", nil);
    [punchClient close];
  }
  return 0;
}
