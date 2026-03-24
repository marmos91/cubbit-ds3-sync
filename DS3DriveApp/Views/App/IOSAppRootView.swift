#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Root view that routes between login and main dashboard based on authentication state.
    /// No tutorial screen -- after first login, straight to dashboard (per CONTEXT.md).
    struct IOSAppRootView: View {
        @Environment(DS3Authentication.self) private var ds3Authentication

        var body: some View {
            Group {
                if ds3Authentication.isLogged {
                    IOSMainTabView()
                } else {
                    IOSLoginView()
                }
            }
            .animation(IOSAnimations.transition, value: ds3Authentication.isLogged)
        }
    }
#endif
