//
//  GMEvent.swift
//  SMS TN
//
//  Typed events decoded from the Gmbridge event stream.
//

import Foundation

private nonisolated struct ReadyPayload: Decodable {
    var sessionID: String?
    var conversations: [PJConversation]?
}

private nonisolated struct MessageEventPayload: Decodable {
    var isOld: Bool?
    var message: PJMessage?
}

private nonisolated struct ConversationEventPayload: Decodable {
    var conversation: PJConversation?
}

nonisolated enum GMEvent: Sendable {
    case pairSuccessful(phoneID: String)
    case ready(sessionID: String, conversations: [PJConversation])
    case message(PJMessage, isOld: Bool)
    case conversation(PJConversation)
    case typing(conversationID: String, started: Bool)
    case settingsUpdated
    case userAlert(String)
    case browserActive
    case authTokenRefreshed
    case listenFatal(String)
    case listenTemporaryError(String)
    case listenRecovered
    case phoneNotResponding
    case phoneRespondingAgain
    case pingFailed(String)
    case gaiaLoggedOut
    case accountChange(account: String, enabled: Bool)
    case noDataReceived
    case pairRevoked
    case gaiaEmoji(String)
    case gaiaError(String)
    case unknown(type: String)

    /// Decodes a (type, payload JSON) pair coming from the Go bridge.
    static func decode(type: String, payloadJSON: String) -> GMEvent {
        let data = Data(payloadJSON.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        switch type {
        case "pair_successful":
            return .pairSuccessful(phoneID: obj["phoneID"] as? String ?? "")
        case "ready":
            let payload = (try? PJ.decode(ReadyPayload.self, from: payloadJSON))
            return .ready(sessionID: payload?.sessionID ?? "",
                          conversations: payload?.conversations ?? [])
        case "message":
            guard let payload = try? PJ.decode(MessageEventPayload.self, from: payloadJSON),
                  let message = payload.message else {
                return .unknown(type: "message(undecodable)")
            }
            return .message(message, isOld: payload.isOld ?? false)
        case "conversation":
            guard let payload = try? PJ.decode(ConversationEventPayload.self, from: payloadJSON),
                  let conversation = payload.conversation else {
                return .unknown(type: "conversation(undecodable)")
            }
            return .conversation(conversation)
        case "typing":
            return .typing(conversationID: obj["conversationID"] as? String ?? "",
                           started: obj["started"] as? Bool ?? false)
        case "settings":
            return .settingsUpdated
        case "user_alert":
            return .userAlert(obj["alertType"] as? String ?? "")
        case "browser_active":
            return .browserActive
        case "auth_token_refreshed":
            return .authTokenRefreshed
        case "listen_fatal":
            return .listenFatal(obj["error"] as? String ?? "")
        case "listen_temp_error":
            return .listenTemporaryError(obj["error"] as? String ?? "")
        case "listen_recovered":
            return .listenRecovered
        case "phone_not_responding":
            return .phoneNotResponding
        case "phone_responding_again":
            return .phoneRespondingAgain
        case "ping_failed":
            return .pingFailed(obj["error"] as? String ?? "")
        case "gaia_logged_out":
            return .gaiaLoggedOut
        case "account_change":
            return .accountChange(account: obj["account"] as? String ?? "",
                                  enabled: obj["enabled"] as? Bool ?? false)
        case "no_data_received":
            return .noDataReceived
        case "pair_revoked":
            return .pairRevoked
        case "gaia_emoji":
            return .gaiaEmoji(obj["emoji"] as? String ?? "")
        case "gaia_error":
            return .gaiaError(obj["error"] as? String ?? "")
        default:
            return .unknown(type: type)
        }
    }
}
