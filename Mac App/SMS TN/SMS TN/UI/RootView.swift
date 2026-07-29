//
//  RootView.swift
//  SMS TN
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .needsPairing:
                PairingView()

            case .ready:
                MainSplitView()

            case .fatal(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ConversationListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if model.selectedConversationID != nil {
                ThreadView()
            } else {
                Text("Select a conversation")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connectionState != .connected {
            HStack(spacing: 8) {
                if model.connectionState == .connecting || model.connectionState == .reconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.slash")
                }
                Text(model.connectionState.label)
                    .font(.callout)
                Spacer()
                if model.connectionState == .disconnected {
                    Button("Reconnect") { model.retryConnect() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bannerColor.opacity(0.15))
        } else if model.syncRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08))
        }
    }

    private var bannerColor: Color {
        switch model.connectionState {
        case .phoneNotResponding, .disconnected: return .orange
        default: return .blue
        }
    }
}
