//
//  ThreadView.swift
//  SMS TN
//
//  Message thread with inline media (spec §3.1) and composer.
//

import AppKit
import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(ContactsService.self) private var contacts
    @State private var draft = ""
    @State private var showAttachmentPicker = false
    @State private var showAttachMenu = false
    @State private var photoItem: PhotosPickerItem?

    private var conversation: ConversationRecord? {
        model.conversations.first { $0.id == model.selectedConversationID }
    }

    /// Display name resolved via Contacts (v3 server conversations carry no
    /// name of their own), falling back to the stored name / phone number.
    private var displayTitle: String {
        guard let conversation else { return "" }
        if let number = conversation.primaryNumber,
           let name = contacts.match(for: number)?.name, !name.isEmpty {
            return name
        }
        if !conversation.name.isEmpty { return conversation.name }
        return conversation.primaryNumber ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.threadMessages) { message in
                            MessageBubble(message: message,
                                          media: model.threadMedia[message.id] ?? [],
                                          isRCS: conversation?.type == "RCS")
                                .id(message.id)
                        }
                        if let id = model.selectedConversationID,
                           model.typingConversationIDs.contains(id) {
                            TypingIndicatorBubble()
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: model.threadMessages.last?.id) { _, lastID in
                    if let lastID {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let lastID = model.threadMessages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            Divider()
            if conversation?.readOnly ?? false {
                notAvailableBanner
            } else {
                composer
            }
        }
        .navigationTitle(displayTitle)
        .navigationSubtitle(subtitle)
    }

    private var notAvailableBanner: some View {
        Text("Messaging with \(displayTitle.isEmpty ? "this sender" : displayTitle) is not available right now")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.gray.opacity(0.08))
    }

    private var subtitle: String {
        guard let conversation else { return "" }
        var parts: [String] = []
        if let type = conversation.type { parts.append(type) }
        if conversation.readOnly { parts.append("read only") }
        return parts.joined(separator: " · ")
    }

    private var sendColor: Color {
        conversation?.type == "RCS" ? Theme.sentRCS : Theme.sentSMS
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Attach menu: Photos/Videos or a regular file.
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAttachMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $photoItem,
                                 matching: .any(of: [.images, .videos])) {
                        Label("Photos & Videos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .onChange(of: photoItem) { _, _ in showAttachMenu = false }

                    Divider()

                    Button {
                        showAttachMenu = false
                        showAttachmentPicker = true
                    } label: {
                        Label("Attach File…", systemImage: "paperclip")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(width: 210)
            }
            .fileImporter(isPresented: $showAttachmentPicker,
                          allowedContentTypes: [.image, .movie, .audio, .pdf, .data]) { result in
                if case .success(let url) = result {
                    let caption = draft
                    draft = ""
                    Task {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        await model.sendAttachment(fileURL: url, caption: caption)
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                let caption = draft
                draft = ""
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ut = item.supportedContentTypes.first
                        let mime = ut?.preferredMIMEType ?? "application/octet-stream"
                        let ext = ut?.preferredFilenameExtension ?? "dat"
                        await model.sendAttachmentData(data, fileName: "attachment.\(ext)",
                                                       mimeType: mime, caption: caption)
                    }
                    photoItem = nil
                }
            }

            // Emoji picker (system Character Viewer inserts into the field).
            Button {
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 3)

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.5)))
                .onChange(of: draft) { _, newValue in
                    if !newValue.isEmpty { model.userIsTyping() }
                }
                // Enter sends; Shift+Enter inserts a newline.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    send()
                    return .handled
                }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? sendColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(10)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(conversation?.readOnly ?? true)
            && model.connectionState == .connected
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await model.sendText(text) }
    }
}

struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: MessageRecord
    let media: [MediaRecord]
    var isRCS: Bool = false

    // Cap bubble width like iMessage rather than letting it span the pane.
    private let maxBubbleWidth: CGFloat = 460

    /// Right-click actions for a message. Copy is only offered when there's text
    /// (selection + Cmd+C also works on the bubble); Delete removes it locally
    /// and pushes the removal to the server, which broadcasts it to Android.
    @ViewBuilder private var messageMenu: some View {
        if !message.textContent.isEmpty {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.textContent, forType: .string)
            }
        }
        Button("Delete Message", role: .destructive) {
            model.deleteMessage(message.id)
        }
    }

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 80) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                ForEach(media, id: \.mediaID) { item in
                    MediaContentView(media: item)
                }
                if !message.textContent.isEmpty {
                    // AppKit-backed so the message text is drag-selectable (Cmd+C)
                    // AND we can inject "Delete Message" straight into the native
                    // right-click menu — SwiftUI's Text gives no hook into it.
                    SelectableTextView(
                        text: message.textContent,
                        textColor: message.isFromMe ? .white : .labelColor,
                        maxWidth: maxBubbleWidth - 24,   // minus the bubble's h-padding
                        onDelete: { model.deleteMessage(message.id) })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: maxBubbleWidth,
                               alignment: message.isFromMe ? .trailing : .leading)
                }
                if !message.decodedReactions.isEmpty {
                    Text(message.decodedReactions.compactMap(\.data?.unicode).joined(separator: " "))
                        .font(.caption)
                }
                if message.isFailed {
                    HStack(spacing: 3) {
                        Text("Not Delivered")
                            .font(.caption2.weight(.semibold))
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                    }
                    .foregroundStyle(.red)
                } else {
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Right-click anywhere on the bubble (media, status line, padding)
            // also gets the menu, so media-only messages are deletable too.
            .contextMenu { messageMenu }
            if !message.isFromMe { Spacer(minLength: 80) }
        }
        .padding(.horizontal, 12)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.isFromMe {
            if message.isIMessage { return AnyShapeStyle(Theme.sentIMessage) }
            return AnyShapeStyle(isRCS ? Theme.sentRCS : Theme.sentSMS)
        }
        return AnyShapeStyle(Color.gray.opacity(0.2))
    }

    private var dateLabel: String {
        let date = message.date
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return time
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusLine: String {
        let service = message.isIMessage ? "iMessage" : (isRCS ? "RCS" : "SMS")
        var parts = ["\(dateLabel) \(service)"]
        if message.isFromMe {
            switch message.status {
            case "OUTGOING_SENDING", "OUTGOING_YET_TO_SEND": parts.append("sending…")
            case "OUTGOING_DELIVERED": parts.append("delivered")
            case "OUTGOING_DISPLAYED": parts.append("read")
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }
}

struct MediaContentView: View {
    @Environment(AppModel.self) private var model
    let media: MediaRecord
    @State private var localURL: URL?

    private let maxSide: CGFloat = 320

    /// Fit [size] within max×max without upscaling.
    private func fittedSize(for size: CGSize, max: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: max, height: max) }
        let scale = Swift.min(max / size.width, max / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        Group {
            if let url = localURL {
                if media.isImage, let image = NSImage(contentsOf: url) {
                    // Size the frame to the image's actual fitted dimensions so the
                    // rounded clip hugs the photo (a maxWidth/maxHeight frame leaves
                    // a transparent letterbox and the corners look square).
                    let fitted = fittedSize(for: image.size, max: maxSide)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { NSWorkspace.shared.open(url) }
                } else if media.isVideo || media.isAudio {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(width: maxSide, height: media.isAudio ? 48 : 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    fileChip(url: url)
                }
            } else {
                placeholder
            }
        }
        .task(id: media.localFileName) {
            if let store = model.mediaStoreRef {
                localURL = await store.url(for: media)
            }
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            switch media.state {
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                Text("Download failed")
                Button("Retry") {
                    Task { await model.mediaStoreRef?.retryFailed() }
                }
                .controlSize(.small)
            default:
                ProgressView().controlSize(.small)
                Text(media.fileName ?? "Downloading…")
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    private func fileChip(url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                VStack(alignment: .leading) {
                    Text(media.fileName ?? url.lastPathComponent)
                        .lineLimit(1)
                    if media.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: media.size,
                                                       countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }
}

/// Selectable message text backed by NSTextView. Supports drag-selection and
/// Cmd+C like normal text, and injects a "Delete Message" item into the native
/// right-click menu (SwiftUI's `Text` exposes no way to add to that menu).
/// Auto-sizes to its content up to `maxWidth`. Requires macOS 13+ for
/// `sizeThatFits`.
private struct SelectableTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    let maxWidth: CGFloat
    let onDelete: () -> Void

    private var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    func makeNSView(context: Context) -> MessageTextView {
        let tv = MessageTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: MessageTextView, context: Context) {
        tv.onDelete = onDelete
        tv.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor]))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let width = min(maxWidth, proposal.width ?? maxWidth)
        let rect = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

/// NSTextView that appends "Delete Message" to the standard selection menu.
final class MessageTextView: NSTextView {
    var onDelete: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Delete Message",
                              action: #selector(performDeleteMessage), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func performDeleteMessage() { onDelete?() }
}

struct TypingIndicatorBubble: View {
    @State private var phase = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(phase ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever()
                            .delay(Double(index) * 0.2), value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.gray.opacity(0.2)))
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
        .onAppear { phase = true }
    }
}
