import Foundation
import OSLog

/// Enable OPENRUNG_MEMORY_DIAGNOSTICS on a Release internal build to collect
/// running extension footprint without debug libbox logs. No memory number is
/// treated as acceptance until a physical-device trace meets the agreed budget.
final class EngineMemoryMonitor {
    #if OPENRUNG_MEMORY_DIAGNOSTICS
    private let queue = DispatchQueue(label: "com.openrung.app.engine-memory")
    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "EngineMemory")
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0
    private var samples = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            peak = 0
            samples = 0
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.sample("running") }
            timer = source
            source.resume()
        }
    }
    func mark(_ stage: String) { queue.async { [self] in sample(stage) } }
    func stop() {
        queue.sync { sample("stopped"); timer?.cancel(); timer = nil }
    }
    private func sample(_ stage: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        peak = max(peak, info.phys_footprint)
        samples += 1
        if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier),
           let data = try? JSONSerialization.data(withJSONObject: ["stage": stage, "app_version": DeviceAttributes.appVersion, "footprint_bytes": info.phys_footprint, "sampled_peak_bytes": peak, "samples": samples, "measured_at": ISO8601DateFormatter().string(from: Date())]) {
            try? data.write(to: directory.appendingPathComponent("engine-memory.json"), options: .atomic)
        }
        logger.info("stage=\(stage, privacy: .public) footprint_bytes=\(info.phys_footprint) sampled_peak_bytes=\(self.peak)")
    }
    deinit { timer?.cancel() }
    #else
    func start() {}
    func mark(_ stage: String) {}
    func stop() {}
    #endif
}
