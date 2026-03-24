import Foundation

/// An accountSession in the Cubbit DS3 ecosystem
@Observable
public final class AccountSession: Codable, @unchecked Sendable {
    private var _token: Token

    /// An authentication token used to authenticate the root user
    public var token: Token {
        _token
    }

    private var _refreshToken: String

    /// A refresh token used to refresh the authentication token
    public var refreshToken: String {
        _refreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case _token = "token"
        case _refreshToken = "refreshToken"
    }

    public init(token: Token, refreshToken: String) {
        self._token = token
        self._refreshToken = refreshToken
    }

    /// Updates the token
    /// - Parameter token: the new token
    public func refreshToken(token: Token) {
        self._token = token
    }

    /// Updates the refresh token
    /// - Parameter refreshToken: the new refresh token
    public func refreshRefreshToken(refreshToken: String) {
        self._refreshToken = refreshToken
    }

    /// Updates both the token and the refresh token
    /// - Parameters:
    ///  - token: the new token
    ///  - refreshToken: the new refresh token
    public func refreshTokens(token: Token, refreshToken: String) {
        self.refreshToken(token: token)
        self.refreshRefreshToken(refreshToken: refreshToken)
    }

    // MARK: - Codable

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        _token = try container.decode(Token.self, forKey: ._token)
        _refreshToken = try container.decode(String.self, forKey: ._refreshToken)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.token, forKey: ._token)
        try container.encode(self.refreshToken, forKey: ._refreshToken)
    }
}
