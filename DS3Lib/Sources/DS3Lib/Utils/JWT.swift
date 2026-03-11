import Foundation

enum JWTError: Error, LocalizedError {
    case parse
    case encoding
    case jsonDecoding
}

/// Decodes a given JWT refresh token without validating its signature
/// - Parameter token: the jwt containing the refreshed token
/// - Throws: JWTError, if it fails to decode
/// - Returns: the parsed refresh token
func jwtDecodeRefreshToken(token: String) throws -> RefreshToken {
    let slices = token.split(separator: ".")
    
    guard slices.count > 1 else { throw JWTError.parse }
    guard let utf8Decoded = slices[1].data(using: .utf8) else { throw JWTError.encoding }
    guard let data = Data(base64Encoded: utf8Decoded) else { throw JWTError.encoding }
    
    guard let refreshToken = try? JSONDecoder().decode(RefreshToken.self, from: data) else { throw JWTError.jsonDecoding }
    
    return refreshToken
}
