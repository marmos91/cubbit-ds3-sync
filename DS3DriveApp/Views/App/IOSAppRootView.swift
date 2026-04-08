#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Root view that routes between login, tutorial, and main dashboard
    /// based on authentication state and first-run status. The tutorial
    /// is shown once per install after the first successful login, gated
    /// by the shared `tutorialShown` `AppStorage` key.
    struct IOSAppRootView: View {
        @Environment(DS3Authentication.self) private var ds3Authentication
        @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) private var tutorialShown: Bool = DefaultSettings
            .tutorialShown

        var body: some View {
            ZStack {
                IOSColors.background
                    .ignoresSafeArea()

                Group {
                    if ds3Authentication.isLogged {
                        if tutorialShown {
                            IOSMainTabView()
                        } else {
                            IOSTutorialView()
                        }
                    } else {
                        IOSLoginView()
                    }
                }
                .animation(IOSAnimations.transition, value: ds3Authentication.isLogged)
                .animation(IOSAnimations.transition, value: tutorialShown)
            }
        }
    }
#endif
