  //
//  ContactsService.swift
//  SMS TN
//
//  Resolves contact display names and photos by phone number from the
//  macOS Contacts database. Read-only; access is requested once and
//  results are cached in memory for the session.
//

import AppKit
import Contacts
import Foundation

@MainActor
@Observable
final class ContactsService {
    struct Match: Sendable {
        var name: String?
        var image: NSImage?
    }

    private(set) var authorized = false
    private var cache: [String: Match] = [:]       // normalized number -> match
    private let store = CNContactStore()
    private var loadTask: Task<Void, Never>?

    /// Requests access and preloads contacts into the cache.
    func requestAccessAndLoad() {
        loadTask = Task {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            self.authorized = granted
            guard granted else { return }
            await self.loadAll()
        }
    }

    /// Returns a cached match for a phone number, if any.
    func match(for phoneNumber: String) -> Match? {
        cache[Self.normalize(phoneNumber)]
    }

    private func loadAll() async {
        // CNContactFormatter requires its own descriptor keys; requesting
        // only name keys crashes with "a property was not requested".
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var built: [String: Match] = [:]
        // Fetch off the main actor; enumerate is synchronous/blocking.
        let store = self.store
        let collected: [(String, Match)] = await Task.detached {
            var out: [(String, Match)] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                var image: NSImage?
                if let data = contact.thumbnailImageData {
                    image = NSImage(data: data)
                }
                for phone in contact.phoneNumbers {
                    let normalized = ContactsService.normalize(phone.value.stringValue)
                    guard !normalized.isEmpty else { continue }
                    out.append((normalized, Match(name: name, image: image)))
                }
            }
            return out
        }.value
        for (number, match) in collected {
            built[number] = match
        }
        cache = built
    }

    /// Normalizes a phone number to its last 9 significant digits so
    /// local/international formatting variations still match.
    nonisolated static func normalize(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count > 9 {
            return String(digits.suffix(9))
        }
        return digits
    }
}
