import Foundation

/// The Cubbit related API URLs.
enum CubbitAPIURLs {
    static let baseURL = "https://api.cubbit.eu"
    
    /// IAM service related URLs.
    enum IAM {
        static let baseURL = "\(CubbitAPIURLs.baseURL)/iam/v1"
        
        enum auth {
            static let baseURL = "\(IAM.baseURL)/auth"

            static let signinURL = "\(auth.baseURL)/signin"
            static let challengeURL = "\(auth.signinURL)/challenge"
            static let tokenRefreshURL = "\(auth.baseURL)/refresh/access"
            static let forgeAccessJWTURL = "\(auth.baseURL)/forge/access"
        }
        
        enum accounts {
            static let baseURL = "\(IAM.baseURL)/accounts"
            
            static let meURL = "\(accounts.baseURL)/me"
        }
        
        
    }
    
    enum composerHub {
        static let baseURL = "\(CubbitAPIURLs.baseURL)/composer-hub/v1"
        
        static let projects = "\(composerHub.baseURL)/projects"
    }
    
    /// Cubbit's internal KMS related URLs.
    enum keyvault {
        static let baseURL = "\(CubbitAPIURLs.baseURL)/keyvault/api/v3"
        
        static let createKeyURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
        static let getKeysURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
        static let deleteKeyURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
    }
}

/// Cubbits web console related URLs.
enum ConsoleURLs {
    static let baseURL = "https://console.cubbit.eu"
    
    static let signupURL = "\(ConsoleURLs.baseURL)/signup"
    static let recoveryURL = "\(ConsoleURLs.baseURL)/recovery"
    static let workspaceURL = "\(ConsoleURLs.baseURL)/workspace"
    static let projectsURL = "\(ConsoleURLs.workspaceURL)/projects"
    static let profileURL = "\(ConsoleURLs.workspaceURL)/profile"
}

/// Cubbit docs related URLs.
enum DocsURLs {
    static let baseURL = "https://docs.cubbit.io"
}

/// Cubbit help center related URLs.
enum HelpURLs {
    static let baseURL = "https://help.cubbit.io"
}
