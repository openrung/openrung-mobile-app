#import <React/RCTBridgeModule.h>

// iOS-only preferences for the home-screen widget. Not part of the OpenRungVpn contract.
@interface RCT_EXTERN_MODULE (OpenRungWidget, NSObject)

RCT_EXTERN_METHOD(setLanguageTag : (NSString *)tag)

@end
