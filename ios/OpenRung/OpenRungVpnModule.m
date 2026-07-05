#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Exposes the Swift OpenRungVpnModule (runtime class name "OpenRungVpn") to React Native as the
// NativeModule "OpenRungVpn" (contract §3). Event: "openrungStateChanged".
@interface RCT_EXTERN_MODULE (OpenRungVpn, RCTEventEmitter)

RCT_EXTERN_METHOD(prepare : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(connect : (NSString *)brokerUrl targetCountry : (NSString *_Nullable)targetCountry
                      resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(disconnect : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getState : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getIdentity : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getTrafficStats : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(measureLatency : (NSArray *)targets timeoutMs : (nonnull NSNumber *)timeoutMs
                      resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getInstalledApps : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getSplitTunnelConfig : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setSplitTunnelConfig : (NSDictionary *)config
                      resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getPersistedLog : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(clearPersistedLog : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject)

@end
