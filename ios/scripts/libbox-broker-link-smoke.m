#import <Foundation/Foundation.h>
#import <Libbox/Libbox.h>

// Build-only executable used by build-libbox-release.sh. It is linked but never
// run; calling the constructor ensures Libbox's static Go archive and native
// resolver references are actually pulled into both Apple slice link checks.
int main(void) {
  @autoreleasepool {
    id<LibboxOpenRungBrokerOperation> operation =
        LibboxNewOpenRungBrokerOperationForIOS(@"link-smoke", @"build");
    [operation close];
    id<LibboxOpenRungBrokerOperation> reactNativeOperation =
        LibboxNewOpenRungBrokerOperationForReactNative(@"link-smoke", @"ios");
    [reactNativeOperation close];
  }
  return 0;
}
