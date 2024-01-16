import Foundation

func apiKeyName(forUser user: IAMUser, projectName: String) -> String {
    return "\(DefaultSettings.apiKeyNamePrefix)(\(user.username)_\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(DefaultSettings.appUUID))"
}

