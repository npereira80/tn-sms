//
//  ConversationListView.swift
//  SMS TN
//

import AppKit
import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @Environment(ContactsService.self) private var contacts
    @State private var searchText = ""
    @State private var showCompose = false

    private var filtered: [ConversationRecord] {
        guard !searchText.isEmpty else { return model.conversations }
        return model.conversations.filter {
            displayName(for: $0).localizedCaseInsensitiveContains(searchText)
                || ($0.snippet ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var pinned: [ConversationRecord] {
        model.conversations.filter(\.pinned)
    }

    // Pinned appear as circles in the header; drop them from the linear
    // list (unless searching, where everything is shown flat).
    private var listRows: [ConversationRecord] {
        (searchText.isEmpty && !pinned.isEmpty) ? filtered.filter { !$0.pinned } : filtered
    }

    var body: some View {
        List(selection: Binding(
            get: { model.selectedConversationID },
            set: { model.selectConversation($0) }
        )) {
            if !pinned.isEmpty && searchText.isEmpty {
                PinnedRow(pinned: pinned,
                          resolve: contactMatch,
                          displayName: displayName,
                          onSelect: { model.selectConversation($0) })
                    .listRowInsets(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6))
            }
            ForEach(listRows) { conversation in
                ConversationRow(conversation: conversation,
                                contact: contactMatch(conversation),
                                displayName: displayName(for: conversation),
                                isTyping: model.typingConversationIDs.contains(conversation.id))
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Delete Conversation", role: .destructive) {
                            model.deleteThread(conversation.id)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner()
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .navigationTitle("Messages")
        .toolbar {
            ToolbarItem {
                Button {
                    showCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Message")
                .disabled(model.phase != .ready)
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView()
        }
    }

    private func contactMatch(_ c: ConversationRecord) -> ContactsService.Match? {
        guard let number = c.primaryNumber else { return nil }
        return contacts.match(for: number)
    }

    private func displayName(for c: ConversationRecord) -> String {
        if let name = contactMatch(c)?.name, !name.isEmpty { return name }
        if !c.name.isEmpty { return c.name }
        return c.primaryNumber ?? "Unknown"
    }
}

// MARK: - Pinned header

private struct PinnedRow: View {
    let pinned: [ConversationRecord]
    let resolve: (ConversationRecord) -> ContactsService.Match?
    let displayName: (ConversationRecord) -> String
    let onSelect: (String) -> Void

    var body: some View {
        Group {
            if pinned.count <= 2 {
                HStack(spacing: 24) {
                    Spacer(minLength: 0)
                    ForEach(pinned) { pin in cell(pin) }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(pinned) { pin in cell(pin) }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func cell(_ pin: ConversationRecord) -> some View {
        Button {
            onSelect(pin.id)
        } label: {
            VStack(spacing: 6) {
                AvatarView(name: displayName(pin),
                           hexColor: pin.avatarHexColor,
                           image: resolve(pin)?.image,
                           isGroup: pin.isGroupChat,
                           size: 56)
                Text(displayName(pin))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

struct ConversationRow: View {
    let conversation: ConversationRecord
    let contact: ContactsService.Match?
    let displayName: String
    let isTyping: Bool

    var body: some View {
        HStack(spacing: 11) {
            AvatarView(name: displayName,
                       hexColor: conversation.avatarHexColor,
                       image: contact?.image,
                       isGroup: conversation.isGroupChat,
                       size: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        .font(.body.weight(conversation.unread ? .semibold : .regular))
                        .lineLimit(1)
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.timeLabel(for: conversation.lastMessageDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if isTyping {
                        Text("typing…")
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.blue)
                    } else {
                        Text(conversation.snippet ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if conversation.unread {
                        Circle()
                            .fill(.blue)
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
        .padding(.vertical, 11)
    }

    static func timeLabel(for date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let name: String
    let hexColor: String?
    var image: NSImage? = nil
    var isGroup = false
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(color)
                    if isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(.white)
                    } else {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        if letters.isEmpty { return "#" }
        return letters.uppercased()
    }

    private var color: Color {
        if let hexColor, let parsed = Color(hexString: hexColor) {
            return parsed
        }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]
        let index = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[index]
    }
}

extension Color {
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let r, g, b: Double
        if hex.count == 8 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b)
    }
}
