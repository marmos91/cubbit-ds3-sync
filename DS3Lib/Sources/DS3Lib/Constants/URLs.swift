import Foundation

/// The Cubbit related API URLs.
public enum CubbitAPIURLs {
    public static let baseURL = "https://api.eu00wi.cubbit.services"

    /// IAM service related URLs.
    public enum IAM {
        public static let baseURL = "\(CubbitAPIURLs.baseURL)/iam/v1"

        public enum auth {
            public static let baseURL = "\(IAM.baseURL)/auth"
            public static let signinURL = "\(auth.baseURL)/signin"
            public static let challengeURL = "\(auth.signinURL)/challenge"
            public static let tokenRefreshURL = "\(auth.baseURL)/refresh/access"
            public static let forgeAccessJWTURL = "\(auth.baseURL)/forge/access"
        }

        public enum accounts {
            public static let baseURL = "\(IAM.baseURL)/accounts"
            public static let meURL = "\(accounts.baseURL)/me"
        }
    }

    public enum composerHub {
        public static let baseURL = "\(CubbitAPIURLs.baseURL)/composer-hub/v1"
        public static let projects = "\(composerHub.baseURL)/projects"
    }

    /// Cubbit's internal KMS related URLs.
    public enum keyvault {
        public static let baseURL = "\(CubbitAPIURLs.baseURL)/keyvault/api/v3"
        public static let createKeyURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
        public static let getKeysURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
        public static let deleteKeyURL = "\(CubbitAPIURLs.keyvault.baseURL)/keys"
    }
}

/// Cubbit web console related URLs.
public enum ConsoleURLs {
    public static let baseURL = "https://console.cubbit.eu"
    public static let signupURL = "\(ConsoleURLs.baseURL)/signup"
    public static let recoveryURL = "\(ConsoleURLs.baseURL)/recovery"
    public static let workspaceURL = "\(ConsoleURLs.baseURL)/workspace"
    public static let projectsURL = "\(ConsoleURLs.workspaceURL)/projects"
    public static let profileURL = "\(ConsoleURLs.workspaceURL)/profile"
}

/// Cubbit docs related URLs.
public enum DocsURLs {
    public static let baseURL = "https://docs.cubbit.io"
}

/// Cubbit help center related URLs.
public enum HelpURLs {
    public static let baseURL = "https://help.cubbit.io"
}
