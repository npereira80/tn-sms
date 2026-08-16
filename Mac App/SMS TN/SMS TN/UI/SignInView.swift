//
//  SignInView.swift
//  SMS TN
//
//  Attaching this Mac to one family member's account on the sync server.
//
//  The Mac has no SIM, so it can't prove a phone number the way the Android app
//  does (which texts itself). Instead the server pushes a code to the devices
//  already signed in to that account — in practice the person's phone — and it's
//  typed here. Having the phone in hand is the proof.
//

import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var email = ""
    @State private var code = ""
    @State private var working = false
    /// Shown only when nobody was online to receive the pushed code, so the
    /// server handed it back rather than locking the person out.
    @State private var fallbackCode: String?

    private var awaitingCode: Bool { model.signInPending != nil }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Sign in")
                .font(.title2.weight(.semibold))

            Text(awaitingCode
                 ? "Enter the code from your phone."
                 : "Your email identifies your account on the family server. "
                 + "Each person's messages are kept separately.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if awaitingCode {
                TextField("000000", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .multilineTextAlignment(.center)
                    .font(.system(.title3, design: .monospaced))
                    .onSubmit(submitCode)

                if let fallbackCode {
                    // No device was online to show it. Displaying it here is no
                    // weaker than the phone's self-text: the shared secret is
                    // what stands between a stranger and this screen.
                    Text("No device was online, so here it is: \(fallbackCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(submitEmail)
            }

            if let message = model.signInMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 10) {
                if awaitingCode {
                    Button("Start over") {
                        code = ""
                        fallbackCode = nil
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button(awaitingCode ? "Sign in" : "Continue") {
                    awaitingCode ? submitCode() : submitEmail()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (awaitingCode ? code.count < 6 : !email.contains("@")))
            }

            if working { ProgressView().controlSize(.small) }
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 380)
    }

    private func submitEmail() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), !working else { return }
        working = true
        Task {
            fallbackCode = await model.beginSignIn(email: address)
            working = false
        }
    }

    private func submitCode() {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entered.count >= 6, !working else { return }
        working = true
        Task {
            await model.completeSignIn(code: entered)
            working = false
        }
    }
}
