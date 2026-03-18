import Foundation
import os.log

/// Logs the current physical memory footprint of the process using Darwin task_info.
/// Lightweight enough to leave in production builds (uses OSLog which filters by level).
public func logMemoryUsage(label: String, logger: Logger) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        let mb = Double(info.phys_footprint) / (1024 * 1024)
        logger.info("Memory [\(label, privacy: .public)]: \(String(format: "%.1f", mb), privacy: .public) MB")
    }
}
