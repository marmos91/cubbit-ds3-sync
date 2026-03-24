#if os(macOS)
    @preconcurrency import ServiceManagement

    final class MacOSLifecycleService: LifecycleService {
        var isAutoLaunchEnabled: Bool {
            SMAppService.mainApp.status == .enabled
        }

        func setAutoLaunch(_ enabled: Bool) throws {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        }
    }
#endif
