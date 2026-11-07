#import <React/RCTBridgeModule.h>

// Exposes the Swift OpenRungWidgetModule (runtime class name "OpenRungWidget") as the iOS-only
// NativeModule "OpenRungWidget" (contract §3). It only publishes the in-app language tag for the
// home-screen widget; VPN lifecycle stays on OpenRungVpn.
@interface RCT_EXTERN_MODULE (OpenRungWidget, NSObject)

RCT_EXTERN_METHOD(setLanguageTag : (NSString *)tag resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

@end
