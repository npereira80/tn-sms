//
//  Theme.swift
//  SMS TN
//

import SwiftUI

nonisolated enum Theme {
    static let tint = Color(hexString: "0088FF") ?? .blue          // selection / accent
    static let sentSMS = Color(hexString: "36C95B") ?? .green      // sent SMS bubble
    static let sentRCS = Color(hexString: "1995FE") ?? .blue       // sent RCS bubble
}
