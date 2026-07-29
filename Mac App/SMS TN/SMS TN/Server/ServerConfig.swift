//
//  ServerConfig.swift
//  SMS TN
//
//  Build-time configuration for the self-hosted SMS Sync server (v3).
//  The registration secret is baked in "for now" (personal use), mirroring
//  the Android agent. It must match REGISTRATION_SECRET in the server's .env.
//
//  NOTE (ISO / hygiene): this file contains a shared secret. Keep it out of
//  any public repo; the longer-term plan is per-device pairing so no shared
//  secret ships in the binary.
//

import Foundation

nonisolated enum ServerConfig {
    /// Public Cloudflare Tunnel hostname for the Mac-mini server.
    static let baseURL = URL(string: "https://sms.tn-services.net")!

    /// Must equal the server's REGISTRATION_SECRET.
    static let registrationSecret = "8c2f2eb8802ffbe58662f75590bbfd282733f767df704443"

    /// Label shown for this device in the server's device registry.
    static let deviceLabel = "Mac (SMS TN)"
}
