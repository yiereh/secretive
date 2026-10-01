import CoreGraphics
import Foundation

/// Thrown when a secret requires interactive authentication but the current session
/// cannot provide it.
public enum AuthenticationUnavailableError: Error {
    /// The user session is locked, so user-presence authentication cannot complete.
    case sessionLocked
}

/// Checks whether the current session can satisfy interactive authentication.
public enum SessionPreflight {

    /// Throws ``AuthenticationUnavailableError/sessionLocked`` when `secret` requires
    /// authentication and the session is locked.
    ///
    /// Dispatching a user-presence-gated operation while the session is locked can leave
    /// the request latched onto the lock screen's biometric evaluation, which never
    /// completes while nobody is there to touch the sensor. Failing fast turns that into
    /// an immediate `agent refused operation` on the client.
    public static func assertCanAuthenticate(secret: AnySecret) throws {
        guard secret.authenticationRequirement.required else { return }

        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        if isLocked {
            throw AuthenticationUnavailableError.sessionLocked
        }
    }

}
