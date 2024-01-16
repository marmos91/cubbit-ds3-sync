import SwiftUI

struct PreferencesView: View {
    @State var startAtLogin: Bool = DefaultSettings.appIsLoginItem
    var preferencesViewModel: PreferencesViewModel
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            VStack(alignment: .center) {
                HStack {
                    Text("Preferences")
                        .font(.custom("Nunito", size: 18))
                        .fontWeight(.bold)
                    
                    Spacer()
                }
                
                BorderedSectionView {

                    VStack(alignment: .leading) {
                        Text("Name:")
                            .font(.custom("Nunito", size: 12))
                            .foregroundStyle(Color(.darkWhite))
                        
                        CubbitTextField(
                            placeholder: preferencesViewModel.formatFullName(),
                            text: .constant(preferencesViewModel.formatFullName())
                        )
                        .disabled(true)
                    }
                    .padding(.bottom)
                    
                    VStack(alignment: .leading) {
                        Text("Email:")
                            .font(.custom("Nunito", size: 12))
                            .foregroundStyle(Color(.darkWhite))
                        
                        CubbitTextField(
                            placeholder: preferencesViewModel.mainEmail(),
                            text: .constant(preferencesViewModel.mainEmail())
                        )
                        .disabled(true)
                    }
                    .padding(.bottom)
                    
                
                    VStack(alignment: .leading) {
                        Text("Password:")
                            .font(.custom("Nunito", size: 12))
                            .foregroundStyle(Color(.darkWhite))
                        
                        CubbitTextField(
                            placeholder: preferencesViewModel.formatPassword(),
                            text: .constant(preferencesViewModel.formatPassword()),
                            isSecure: true
                        )
                        .disabled(true)
                    }
                    .padding(.bottom)
                    
                    HStack {
                        Text("2F Authentication:")
                            .font(.custom("Nunito", size: 12))
                            .foregroundStyle(Color(.darkWhite))
                       
                        if preferencesViewModel.account.isTwoFactorEnabled {
                            Text("Enabled")
                                .font(.custom("Nunito", size: 12))
                                .foregroundStyle(Color(.green))
                        } else {
                            Text("Disabled")
                                .font(.custom("Nunito", size: 12))
                                .foregroundStyle(Color(.red))
                        }
                        
                        Spacer()
                    }
                    
                    HStack {
                        Spacer()
                        
                        OutlineLink(
                            text: NSLocalizedString("Edit on web console", comment: "Edit on web console button"),
                            href: ConsoleURLs.profileURL
                        )
                    }
                }
                .padding(.vertical)
                
                BorderedSectionView {
                    VStack(alignment: .leading) {
                        Toggle(isOn: $startAtLogin) {
                            Text("Start Cubbit DS3 sync at login")
                        }.onChange(of: self.startAtLogin) {
                            do {
                                try self.preferencesViewModel.setStartAtLogin(self.startAtLogin)
                            } catch {
                                print(error)
                            }
                        }
                        
                        Text("(If you decide not to start Cubbit at startup, you will not be able to view the synchronized disks)")
                            .font(.custom("Nunito", size: 12))
                            .foregroundStyle(Color(.darkWhite))
                    }
                }
                .padding(.bottom)
                
                Button("Disconnect account") {
                    do {
                        try preferencesViewModel.disconnectAccount()
                    } catch {
                        print(error)
                    }
                }
                .frame(width: 200)
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(50)
        }
        .frame(
            minWidth: 800,
            maxWidth: 800,
            minHeight: 600,
            maxHeight: 600
        )
    }
    
    
}

#Preview {
    PreferencesView(
        preferencesViewModel: PreferencesViewModel(
            account: Account(
                id: UUID().uuidString,
                firstName: "Marco",
                lastName: "Moschettini",
                isInternal: false,
                isBanned: false,
                createdAt: "yesterday",
                maxAllowedProjects: 1,
                emails: [
                    AccountEmail(
                        id: UUID().uuidString,
                        email: "connect@cubbit.io",
                        isDefault: true,
                        createdAt: "yesterday",
                        isVerified: true,
                        tenantId: "tenant"
                    )
                ], 
                isTwoFactorEnabled: true,
                tenantId: "tenant",
                endpointGateway: "https://s3.cubbit.eu",
                authProvider: "cubbit"
            )
        )
    )
}
