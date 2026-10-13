import AIBridge
import Foundation

/// User-facing text produced by the stores (transcript notices and errors). Catalog:
/// `AppCore/Resources/Localizable.xcstrings`.
enum L10n {
    // Assistant transcript
    static var diskToolsNotConnected: String {
        String(localized: "The disk tools did not connect, so Claude cannot see the scan. Try again; the details can help with a bug report.", bundle: .module, comment: "Assistant error when the MCP helper failed to connect")
    }

    static var sessionCrashed: String {
        String(localized: "Claude Code stopped unexpectedly. Try again to pick up the conversation where it left off.", bundle: .module, comment: "Assistant error when the claude process exits with an error")
    }

    static var launchFailed: String {
        String(localized: "Claude Code could not be started. Check Settings, then try again.", bundle: .module, comment: "Assistant error when the claude process could not be launched")
    }

    static var notSignedIn: String {
        String(localized: "Claude Code is not signed in. Open Terminal, run claude and sign in, then try again.", bundle: .module, comment: "Assistant error when the CLI reports an authentication problem")
    }

    static var usageLimit: String {
        String(localized: "Your Claude usage limit is reached for now. It resets later; you can also check your plan in Claude.", bundle: .module, comment: "Assistant error when the account hit its usage limit")
    }

    static func stoppedAfterSteps(_ count: Int) -> String {
        String(localized: "Stopped after \(count) steps. Choose Continue to let Claude keep going.", bundle: .module, comment: "Assistant notice when the per-message step limit was reached")
    }

    static var stopped: String {
        String(localized: "Stopped.", bundle: .module, comment: "Assistant notice after the user pressed Stop")
    }

    static func retrying(_ attempt: Int, _ max: Int) -> String {
        String(localized: "Claude is busy, retrying (\(attempt) of \(max)).", bundle: .module, comment: "Assistant notice while the API is overloaded and the CLI retries")
    }

    static var guardReached: String {
        String(localized: "This conversation reached its usage guard. Choose Continue to allow more, or start a new conversation. The guard can be changed in Settings.", bundle: .module, comment: "Assistant notice when the per-thread token guard is reached")
    }

    static var earlierMessagesHidden: String {
        String(localized: "Earlier messages of this conversation are not shown here, but Claude still remembers them.", bundle: .module, comment: "Assistant notice when reopening a saved conversation")
    }

    static var scanFirst: String {
        String(localized: "Scan a disk or folder first, so the assistant has something to look at.", bundle: .module, comment: "Assistant notice when no scan exists yet")
    }

    static var continueMessage: String {
        String(localized: "Please continue.", bundle: .module, comment: "Message sent to Claude when the user presses Continue after the step limit")
    }

    static var genericTurnError: String {
        String(localized: "Claude could not finish this reply.", bundle: .module, comment: "Assistant error when a turn ended with an unspecified error")
    }

    // API key refusal card (PLAN 3.2b)
    static var refusalTitle: String {
        String(localized: "Stopped: Claude Code would bill an API key", bundle: .module, comment: "Title of the card shown when a session is refused because an API key is in use")
    }

    static func refusalReason(_ origin: APIKeyOrigin) -> String {
        switch origin {
        case .environmentVariable:
            String(localized: "An API key is set in the environment, so usage would be billed to that key instead of your Claude login.", bundle: .module, comment: "Refusal reason: ANTHROPIC_API_KEY environment variable")
        case .keyHelper:
            String(localized: "Claude Code has an API key helper in its settings, so usage would be billed to that key instead of your Claude login.", bundle: .module, comment: "Refusal reason: apiKeyHelper configured in Claude Code settings")
        case .storedKey:
            String(localized: "Claude Code is signed in with a stored API key, so usage would be billed to that key instead of your Claude login.", bundle: .module, comment: "Refusal reason: the CLI uses a stored API key")
        case .other(let source):
            String(localized: "Claude Code reports another API key source (\(source)), so usage would be billed to it instead of your Claude login.", bundle: .module, comment: "Refusal reason: an unknown key source, shown verbatim")
        }
    }

    static var refusalAdvice: String {
        String(localized: "Nothing was sent. Sign in with your Claude account (run claude in Terminal, then /login), or turn off Block API keys in Settings.", bundle: .module, comment: "Refusal card advice")
    }
}
