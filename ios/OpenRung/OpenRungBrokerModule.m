#import <React/RCTBridgeModule.h>

// Exposes the Swift runtime class `OpenRungBroker` as a dedicated classic NativeModule. Keep this
// surface transport-only: WSS ticket methods and credentials must never be exported to JavaScript.
@interface RCT_EXTERN_MODULE(OpenRungBroker, NSObject)

RCT_EXTERN_METHOD(firstReachable : (NSString *)requestId primary : (NSString *)primary
                      limit : (nonnull NSNumber *)limit clientId : (NSString *)clientId
                      sessionId : (NSString *)sessionId resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(runSpeedTest : (NSString *)requestId brokerUrl : (NSString *)brokerUrl
                      resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(sendTelemetryBatchJSON : (NSString *)requestId brokerUrl : (NSString *)brokerUrl
                      batchJson : (NSString *)batchJson resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(fetchManifestCandidate : (NSString *)requestId candidateUrl : (NSString *)candidateUrl
                      resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(cancel : (NSString *)requestId resolver : (RCTPromiseResolveBlock)resolve
                      rejecter : (RCTPromiseRejectBlock)reject)

@end
