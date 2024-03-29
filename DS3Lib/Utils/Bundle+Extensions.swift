import Foundation

extension Bundle {
    /// The application name, as stored in app bundle
    class var applicationName: String {
        if let displayName: String = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String {
            return displayName
        } else if let name: String = Bundle.main.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        
        return "No Name Found"
    }
}
