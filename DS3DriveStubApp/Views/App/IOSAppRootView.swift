#if os(iOS)
import SwiftUI
import DS3Lib

/// Root view that routes between login and main dashboard based on authentication state.
/// No tutorial screen -- after first login, straight to dashboard (per CONTEXT.md).
struct IOSAppRootView: View {
    @Environment(DS3Authentication.self) private var ds3Authentication

    var body: some View {
        if ds3Authentication.isLogged {
            IOSMainTabView()
        } else {
            IOSLoginView()
        }
    }
}
#endif
