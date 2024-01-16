import Foundation

/// An accountSession in the Cubbit DS3 ecosystem
@Observable class AccountSession: Codable {
    private var _token: Token
    var token: Token {
        get { return _token }
    }
    private var _refreshToken: String
    var refreshToken: String {
        get { return _refreshToken }
    }
    
    private enum CodingKeys: String, CodingKey {
        case _token = "token"
        case _refreshToken = "refreshToken"
    }
    
    init(token: Token, refreshToken: String) {
        self._token = token
        self._refreshToken = refreshToken
    }
    
    /// Updates the token
    func refreshToken(token: Token) {
        self._token = token
    }
    
    /// Updates the refresh token
    func refreshRefreshToken(refreshToken: String) {
        self._refreshToken = refreshToken
    }
    
    /// Updates both the token and the refresh token
    func refreshTokens(token: Token, refreshToken: String) {
        self.refreshToken(token: token)
        self.refreshRefreshToken(refreshToken: refreshToken)
    }
    
    // MARK: - Codable
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        _token = try container.decode(Token.self, forKey: ._token)
        _refreshToken = try container.decode(String.self, forKey: ._refreshToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(self.token, forKey: ._token)
        try container.encode(self.refreshToken, forKey: ._refreshToken)
    }
}
