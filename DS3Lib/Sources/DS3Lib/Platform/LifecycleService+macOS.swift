#if os(macOS)
@preconcurrency import ServiceManagement

final class MacOSLifecycleService: LifecycleService {
    var isAutoLaunchEnabled: Bool {
        SMAppService().status == .enabled
    }

    func setAutoLaunch(_ enabled: Bool) throws {
        let service = SMAppService()
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
#endif
