//
//  SmsTapback.swift
//  SMS TN
//
//  When an iPhone user reacts to an SMS (i.e. the thread isn't iMessage), the
//  reaction arrives as a plain SMS like  Liked "your message"  or
//  Maria loved "your message"  or, on newer iOS,  Reacted 😀 to "your message".
//  We parse those so the client can render the reaction as an emoji on the
//  target bubble instead of showing a junk text message.
//

import Foundation

enum SmsTapback {
    struct Result {
        let emoji: String      // the reaction to show
        let quoted: String     // the referenced message text (may be truncated by iOS)
        let removal: Bool      // true = the reaction was removed
    }

    // iOS tapback verb → emoji.
    private static let added: [(verb: String, emoji: String)] = [
        ("loved", "❤️"), ("liked", "👍"), ("disliked", "👎"),
        ("laughed at", "😂"), ("emphasized", "‼️"), ("questioned", "❓"),
    ]
    // "Removed a <thing> from …" → the emoji being removed.
    private static let removed: [(thing: String, emoji: String)] = [
        ("heart", "❤️"), ("like", "👍"), ("dislike", "👎"),
        ("laugh", "😂"), ("exclamation", "‼️"), ("question mark", "❓"),
    ]

    /// Parse a reaction SMS body, or nil if it isn't one. Handles an optional
    /// leading sender name, straight or curly quotes.
    static func parse(_ body: String) -> Result? {
        let s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quoted = quotedText(in: s) else { return nil }
        let lower = s.lowercased()

        for (verb, emoji) in added {
            // "<name> <verb> "…""  or  "<verb> "…""
            if lower.contains("\(verb) \u{201C}") || lower.contains("\(verb) \"") {
                return Result(emoji: emoji, quoted: quoted, removal: false)
            }
        }
        for (thing, emoji) in removed {
            if lower.contains("removed a \(thing) from") || lower.contains("removed an \(thing) from") {
                return Result(emoji: emoji, quoted: quoted, removal: true)
            }
        }
        // Newer iOS custom emoji: Reacted <emoji> to "…"
        if let r = s.range(of: #"(?i)reacted\s+(.+?)\s+to\s+[""]"#, options: .regularExpression) {
            let mid = s[r]
            // pull the emoji between "reacted " and " to"
            if let e = mid.range(of: #"(?i)reacted\s+"#, options: .regularExpression),
               let t = mid.range(of: #"\s+to\s+[""]$"#, options: .regularExpression) {
                let emoji = String(mid[e.upperBound..<t.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !emoji.isEmpty { return Result(emoji: emoji, quoted: quoted, removal: false) }
            }
        }
        return nil
    }

    /// The text inside the first pair of straight or curly double quotes.
    private static func quotedText(in s: String) -> String? {
        let opens: [Character] = ["\u{201C}", "\""]
        let closes: [Character] = ["\u{201D}", "\""]
        guard let start = s.firstIndex(where: { opens.contains($0) }) else { return nil }
        let afterStart = s.index(after: start)
        guard let end = s[afterStart...].lastIndex(where: { closes.contains($0) }), end > afterStart
        else { return nil }
        return String(s[afterStart..<end])
    }

    /// Whether `candidate` (a stored message body) is the message a reaction
    /// quotes. iOS may truncate long messages with an ellipsis, so allow prefix
    /// matches in both directions.
    static func matches(candidate: String, quoted: String) -> Bool {
        let a = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = quoted.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "…")))
        if a.isEmpty || q.isEmpty { return false }
        return a == quoted || a.hasPrefix(q) || q.hasPrefix(a)
    }
}
