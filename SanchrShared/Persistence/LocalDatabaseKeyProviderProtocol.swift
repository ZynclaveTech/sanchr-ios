import Foundation

public enum LocalDatabaseKeyResolution: Sendable {
    case passphrase(String)
    case missingSecretForExistingDatabase
}

public protocol LocalDatabaseKeyProviderProtocol: AnyObject, Sendable {
    func resolveKeyResolution(forDatabaseAt path: String) throws -> LocalDatabaseKeyResolution
    func persistResolvedPassphrase(_ passphrase: String, forDatabaseAt path: String) throws
    func resetDatabaseSecrets() throws
}
