import Foundation

public enum SwiftPadError: Error, Equatable, Sendable {
    case serverUnreachable(String)
    case protocolError(String)
    case notAuthenticated
    case bridgeClosed
    case timeout(String)
    case internalError(String)
    case workerError(code: String, details: [String: String]?)

    case serverConfigRejected(detail: String)

    case partialEviction(failedChannels: [String])

    case authFailed(reason: AuthFailReason)

    case signUpFailed(reason: SignUpFailReason)

    public enum SignUpFailReason: Error, Equatable, Sendable {
        case alreadyRegistered

        case registrationClosed

        case passwordTooShort(minimum: Int)

        case usernameTooLong(maximum: Int)

        case deletedAccount(reason: String)

        case blockWriteFailed(detail: String)
    }

    public enum AuthFailReason: Error, Equatable, Sendable {
        case blockNotFound

        case blockDecryptFailed

        case blockFetchFailed(status: Int)

        case totpRequired

        case totpInvalid

        case totpValidateFailed(detail: String)

        case passwordRequired
    }
}
