import Foundation
import os.log

class SharedData {
    let logger = Logger(subsystem: "io.cubbit.ds3sync.ds3Lib", category: "SharedData")
    static let shared: SharedData = {
        return .init()
    }()
}
