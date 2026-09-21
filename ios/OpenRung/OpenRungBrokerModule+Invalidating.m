// Declares RCTInvalidating conformance for the Swift OpenRungBroker module from Objective-C.
//
// Under Xcode 27 the Swift compiler no longer resolves `RCTInvalidating` through
// `import React` (nor via a textual bridging-header import) against the prebuilt
// React.xcframework, while clang still sees the protocol. React Native only checks
// -conformsToProtocol: at runtime before calling -invalidate, so adopting the protocol in a
// category is behaviourally identical to the previous Swift-side conformance.
#import <React/RCTInvalidating.h>
#import "OpenRung-Swift.h"

@interface OpenRungBroker (RCTInvalidating) <RCTInvalidating>
@end

@implementation OpenRungBroker (RCTInvalidating)
@end
