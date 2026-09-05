#import <Foundation/Foundation.h>
#import <Libbox/Libbox.h>
#import <mach/mach.h>

// Idle-construction measurement only. No engine Start, platform callback,
// network request, TUN, or telemetry session runs in this executable.
@interface EngineMemoryListener : NSObject <LibboxOpenRungEngineListener>
@end
@implementation EngineMemoryListener
- (void)onEvent:(NSString *)eventJSON {}
@end

static uint64_t footprint(void) {
  task_vm_info_data_t info = {0};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
  if (status != KERN_SUCCESS) abort();
  return info.phys_footprint;
}

int main(void) {
  @autoreleasepool {
    // Warm the existing Go runtime first: the delta measures loading the
    // connectcore engine into a process where libbox is already loaded.
    NSString *goVersion = LibboxGoVersion();
    EngineMemoryListener *listener = [EngineMemoryListener new];
    // Construction only retains this identity. Any unexpected platform call
    // crashes the measurement instead of silently inventing a platform result.
    id<LibboxPlatformInterface> platform = (id<LibboxPlatformInterface>)[NSObject new];
    NSMutableArray *engines = [NSMutableArray arrayWithCapacity:1000];
    uint64_t before = footprint();
    uint64_t first = before;
    for (int i = 0; i < 1000; i++) {
      NSError *error = nil;
      id<LibboxOpenRungEngine> engine =
          LibboxNewOpenRungEngineForIOS(@"{}", platform, listener, &error);
      if (!engine || error) { NSLog(@"engine construction failed: %@", error); return 1; }
      [engines addObject:engine];
      if (i == 0) first = footprint();
    }
    uint64_t loaded = footprint();
    printf("Go=%s engines=%lu before=%llu first=%llu loaded=%llu first_delta=%lld aggregate_delta=%lld\n",
           goVersion.UTF8String, (unsigned long)engines.count, before, first, loaded,
           (int64_t)(first-before), (int64_t)(loaded-before));
    // Keep all native handles live through the footprint sample.
    for (id<LibboxOpenRungEngine> engine in engines) [engine stop:1 error:nil];
  }
  return 0;
}
