//
//  ComposeView.swift
//  SMS TN
//
//  New-message composer: enter a phone number and an optional first
//  message, then start the conversation and send.
//

import SwiftUI

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var recipient = ""
    @State private var message = ""
    @State private var sending = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Text("New Message").font(.headline)
                Spacer()
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            .padding(12)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("To:").foregroundStyle(.secondary)
                    TextField("Phone number", text: $recipient)
                        .textFieldStyle(.plain)
                }
                Divider()
                TextField("Message", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...10)

                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if sending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting conversation…").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 460, height: 320)
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespaces).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
            && model.connectionState == .connected
    }

    private func send() {
        guard canSend else { return }
        sending = true
        errorText = nil
        Task {
            let ok = await model.startNewConversation(numbers: [recipient], message: message)
            sending = false
            if ok {
                dismiss()
            } else {
                errorText = "Could not start the conversation. Check the number and that your phone is connected."
            }
        }
    }
}
