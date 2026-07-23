#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Exposes the Swift OpenRungVpnModule (runtime class name "OpenRungVpn") to React Native as the
// NativeModule "OpenRungVpn" (contract §3). Event: "openrungStateChanged".
@interface RCT_EXTERN_MODULE (OpenRungVpn, RCTEventEmitter)

RCT_EXTERN_METHOD(prepare : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(connect : (NSString *)brokerUrl targetCountry : (NSString *_Nullable)targetCountry
                      targetRelayId : (NSString *_Nullable)targetRelayId
                      resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(disconnect : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getState : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getIdentity : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setSplitTunnelConfig : (NSString *)configJson resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

@end
