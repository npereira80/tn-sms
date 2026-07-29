//
//  SMS_TNApp.swift
//  SMS TN
//
//  Created by Nelson Pereira on 16/07/2026.
//  Native macOS client for Google Messages (spec v2).
//

import SwiftUI
import UserNotifications

@main
struct SMS_TNApp: App {
    @State private var model = AppModel()
    @State private var contacts = ContactsService()
    private let notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(contacts)
                .tint(Theme.tint)
                .task {
                    notificationDelegate.model = model
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    contacts.requestAccessAndLoad()
                    await model.start()
                }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Verify Full Sync") {
                    model.runDeepVerify()
                }
                .disabled(model.phase != .ready || model.syncRunning)

                Button("Reconnect") {
                    model.retryConnect()
                }
                .disabled(model.phase != .ready)

                Button("Reset & Re-sync from Server") {
                    model.resyncFromServer()
                }
                .disabled(model.phase != .ready)

                Divider()

                Button("Unpair Phone…") {
                    Task { await model.unpair() }
                }
                .disabled(model.phase != .ready)
            }
        }
    }
}

/// Handles notification actions: OTP copy button and click-to-open.
/// Callbacks can arrive off the main thread, hence nonisolated + explicit
/// MainActor hops.
nonisolated final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == OTPCenter.copyActionID,
           let code = userInfo["otpCode"] as? String {
            await MainActor.run { model?.otpCenter.copyCode(code) }
            return
        }
        if let conversationID = userInfo["conversationID"] as? String {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                model?.selectConversation(conversationID)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
