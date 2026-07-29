//
//  BBSettingsView.swift
//  SMS TN
//
//  Settings sheet to connect the Mac to a BlueBubbles server for iMessage
//  (the Mac unified inbox). URL is stored in UserDefaults, password in Keychain.
//

import SwiftUI

struct BBSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String = BBConfig.serverURL?.absoluteString ?? ""
    @State private var password: String = BBConfig.password ?? ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("iMessage (BlueBubbles)").font(.title3.weight(.semibold))
            Text("Connect to your BlueBubbles server to show iMessage threads alongside SMS. Enter the server URL and password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Server URL", text: $urlString, prompt: Text("https://your-bluebubbles-host"))
                SecureField("Password", text: $password)
            }
            .formStyle(.grouped)

            if let result {
                Label(result, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ok ? .green : .red)
            } else if model.bbConnected {
                Label("Currently connected.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button(testing ? "Connecting…" : "Save & Connect") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(testing || urlString.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        testing = true
        result = nil
        Task {
            let success = await model.configureBlueBubbles(urlString: urlString, password: password)
            testing = false
            ok = success
            result = success
                ? "Connected. iMessage threads will appear shortly."
                : "Couldn't connect. Check the URL and password."
            if success {
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            }
        }
    }
}
