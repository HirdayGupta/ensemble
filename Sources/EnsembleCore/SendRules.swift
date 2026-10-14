import Foundation

/// When a thumbs-up may send what was dictated.
public enum SendRules {
    /// A send is allowed only this long after dictation stopped.
    public static let window: TimeInterval = 30

    /// Why a send must wait or be dropped, or nil. `spokenAgo` is the time since the last dictation stopped
    /// (nil when nothing was dictated); `inputAge` the time since the keyboard, mouse or trackpad was used.
    public static func refusal(spokenAgo: TimeInterval?, inputAge: TimeInterval) -> String? {
        guard let ago = spokenAgo, ago <= window else { return "Nothing dictated in the last \(Int(window)) seconds" }
        return typedSince(spokenAgo: ago, inputAge: inputAge) ? "Typed or clicked since dictation; not sending" : nil
    }

    /// The draft may have been edited by hand after dictation: input more recent than the dictation's end.
    public static func typedSince(spokenAgo: TimeInterval, inputAge: TimeInterval) -> Bool { inputAge < spokenAgo }
}
