//
//  PairingView.swift
//  SMS TN
//
//  Pairing flow. Current Google Messages versions pair via Google account
//  (sign in, then confirm a matching emoji on the phone). QR pairing is
//  offered as a fallback for older phone versions that still show the QR
//  scanner.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model

    enum Method { case google, qr }
    @State private var method: Method = .google
    @State private var showGoogleSignIn = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with your Android phone")
                .font(.largeTitle.bold())

            if model.pairingEmoji != nil || model.googlePairingInProgress {
                emojiConfirmation
            } else {
                Picker("", selection: $method) {
                    Text("Google Account").tag(Method.google)
                    Text("QR Code").tag(Method.qr)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                switch method {
                case .google: googleMethod
                case .qr: qrMethod
                }
            }

            Text("Your phone must stay on and connected for messages to sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showGoogleSignIn) {
            GoogleLoginView { cookies in
                showGoogleSignIn = false
                model.beginGoogleLogin(cookies: cookies)
            } onCancel: {
                showGoogleSignIn = false
            }
        }
        .onChange(of: method) { _, newValue in
            if newValue == .qr { model.beginPairing() } else { model.cancelQRPairing() }
        }
    }

    // MARK: - Google account method

    private var googleMethod: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                instruction(number: 1, text: "Sign in with the **same Google account** used by Google Messages on your phone")
                instruction(number: 2, text: "On your phone, a set of emoji appears. Tap the one shown here")
            }
            .frame(maxWidth: 440, alignment: .leading)

            if let error = model.pairingError {
                errorBox(error) { showGoogleSignIn = true }
            } else {
                Button {
                    showGoogleSignIn = true
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emojiConfirmation: some View {
        VStack(spacing: 18) {
            if let emoji = model.pairingEmoji {
                Text("Confirm on your phone")
                    .font(.title2.bold())
                Text("Tap this emoji in Google Messages on your phone:")
                    .foregroundStyle(.secondary)
                Text(emoji)
                    .font(.system(size: 96))
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.quaternary.opacity(0.4)))
                ProgressView()
                    .controlSize(.small)
            } else if let error = model.pairingError {
                errorBox(error) { showGoogleSignIn = true }
            } else {
                ProgressView()
                Text("Contacting your phone…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: - QR method

    private var qrMethod: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                instruction(number: 1, text: "Open **Google Messages** on your phone")
                instruction(number: 2, text: "Tap your profile picture → **Device pairing**")
                instruction(number: 3, text: "Tap **QR code scanner** and scan the code below")
            }
            .frame(maxWidth: 440, alignment: .leading)

            if let qr = model.pairingQR, let image = Self.qrImage(from: qr) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            } else if let error = model.pairingError {
                errorBox(error) { model.beginPairing() }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Generating QR code…").foregroundStyle(.secondary)
                }
                .frame(width: 244, height: 244)
            }

            Text("If your phone has no QR scanner option, use Google Account instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func instruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.blue.opacity(0.15)))
            Text(.init(text))
        }
    }

    private func errorBox(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Try Again", action: retry)
        }
    }

    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
