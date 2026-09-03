import Foundation

/// What the Help Center shows. Every article describes something the app
/// actually does, in the words the screens use, so a reader can follow it
/// with the app open. Counts, search and categories derive from this list;
/// nothing on the screen is a placeholder.
enum HelpCategory: String, CaseIterable, Identifiable {
    case gettingStarted, security, privacy, chats, calls, backups, troubleshooting, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "Getting Started"
        case .security: "Security"
        case .privacy: "Privacy"
        case .chats: "Chats & Media"
        case .calls: "Calls"
        case .backups: "Backup & Restore"
        case .troubleshooting: "Troubleshooting"
        case .account: "Account"
        }
    }

    var icon: String {
        switch self {
        case .gettingStarted: "sparkles"
        case .security: "lock.shield"
        case .privacy: "eye.slash"
        case .chats: "bubble.left.and.text.bubble.right"
        case .calls: "phone"
        case .backups: "icloud.and.arrow.up"
        case .troubleshooting: "wrench.and.screwdriver"
        case .account: "person.crop.circle"
        }
    }

    var articles: [HelpArticle] { HelpContent.articles.filter { $0.category == self } }
}

/// A settings screen an article can open directly.
enum HelpDestination: String {
    case security, privacy, chatSettings, backup, notifications, storage, appearance, contactUs, registrationLock, blockedContacts

    var label: String {
        switch self {
        case .security: "Open Security"
        case .privacy: "Open Privacy"
        case .chatSettings: "Open Chat Settings"
        case .backup: "Open Backup & Recovery"
        case .notifications: "Open Notifications"
        case .storage: "Open Storage & Data"
        case .appearance: "Open Appearance"
        case .contactUs: "Contact Us"
        case .registrationLock: "Open Registration Lock"
        case .blockedContacts: "Open Blocked Contacts"
        }
    }
}

struct HelpSection: Hashable {
    var heading: String? = nil
    var paragraphs: [String] = []
    /// Numbered instructions, rendered as a list.
    var steps: [String] = []
}

struct HelpArticle: Identifiable, Hashable {
    let id: String
    let category: HelpCategory
    let icon: String
    let title: String
    let summary: String
    let sections: [HelpSection]
    var destination: HelpDestination? = nil

    /// Everything searchable, lowercased.
    var searchText: String {
        ([title, summary] + sections.flatMap { [$0.heading ?? ""] + $0.paragraphs + $0.steps })
            .joined(separator: " ").lowercased()
    }
}

enum HelpContent {
    static func article(_ id: String) -> HelpArticle? { articles.first { $0.id == id } }

    static func search(_ query: String) -> [HelpArticle] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        return articles.filter { article in
            let haystack = article.searchText
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Shown at the top of the Help Center.
    static let popularIDs = ["e2ee", "verify-code", "sanchr-mode", "vault", "backup-enable"]

    static let faqs: [(question: String, answer: String)] = [
        ("How secure is Sanchr?",
         "Messages, calls, photos, files and voice notes are end-to-end encrypted with the Signal Protocol. The keys exist only on your devices, so Sanchr's servers relay ciphertext they cannot read."),
        ("Can Sanchr read my messages if asked to?",
         "No. We do not have the keys. What the server holds is your phone number, your device identifiers and encrypted data in transit. Your name and profile photo are encrypted too."),
        ("What is Sanchr Mode?",
         "A discreet setting under Privacy: notifications arrive without previews and stay silent, and screenshot protection is turned on. Turn it on and off from Settings → Privacy."),
        ("Can I back up my chats?",
         "Yes. Settings → Chats → Backup & Recovery → Enable Backup. Backups are encrypted with a recovery key that only you hold, and stored in your iCloud."),
        ("How do I verify a contact?",
         "Open the conversation, tap the header, choose Security Code, then scan each other's QR code or compare the numbers in person. Tap Mark as Verified when they match."),
        ("Why does a photo say it expired?",
         "Encrypted media waits on the server for a limited time. If it was not downloaded in time, ask the sender to send it again."),
        ("Is there a way to sign out?",
         "No. Sanchr is tied to your phone number on this device. To leave, delete your account from Settings → Security → Delete Account, which erases your account and keys."),
        ("Does Sanchr support video calls?",
         "Voice calls are available now; video calling is being tested and will arrive in a later update."),
    ]

    static let articles: [HelpArticle] = [
        // MARK: Getting started
        HelpArticle(id: "create-account", category: .gettingStarted, icon: "person.badge.plus", title: "Create your account",
                    summary: "Phone number, a code by text, your name and photo.",
                    sections: [
                        HelpSection(paragraphs: ["Sanchr accounts are tied to a phone number. There is no password: you prove you own the number with a one-time code."]),
                        HelpSection(heading: "Steps", steps: [
                            "Pick your country and type your mobile number. The field formats it for your country and tells you if the length is wrong.",
                            "Tap Continue. A 6-digit code arrives by text message; it expires after the time shown on screen.",
                            "Enter the code. If your number has a Registration Lock from an earlier install, you will be asked for that PIN.",
                            "Choose the name your contacts will see and, optionally, a photo. Both are encrypted before they reach the server.",
                            "Decide about notifications, then let Sanchr find contacts who already use it. You can do both later from Settings.",
                        ]),
                    ]),
        HelpArticle(id: "find-contacts", category: .gettingStarted, icon: "person.2", title: "Find your contacts",
                    summary: "Discovery without uploading your address book.",
                    sections: [
                        HelpSection(paragraphs: ["Sanchr can check which of your contacts use the app without learning their numbers: each number is blinded on your phone before the check, so the server answers \"registered or not\" without seeing who you asked about. Names from your address book stay on your device."]),
                        HelpSection(heading: "Steps", steps: [
                            "Open the Contacts tab and tap the add button in the top corner.",
                            "Choose Find friends from contacts and allow access when iOS asks.",
                            "Or choose Add by number or QR to add one person directly.",
                        ]),
                        HelpSection(paragraphs: ["Contacts who join later appear the next time you sync. If someone shows a ~ before their name, that is the name they chose for themselves; saving them in your address book replaces it with yours."]),
                    ]),
        HelpArticle(id: "messaging-basics", category: .gettingStarted, icon: "bubble.left.and.bubble.right", title: "Sending messages and reacting",
                    summary: "Reply, forward, react, copy, save and delete.",
                    sections: [
                        HelpSection(paragraphs: ["Tap a contact to open the conversation. Type in the field at the bottom; by default Return adds a new line and the send button sends. You can make Return send instead in Settings → Chats."]),
                        HelpSection(heading: "Long-press a message to", steps: [
                            "React with an emoji.",
                            "Reply so your message quotes the original.",
                            "Forward it to another conversation.",
                            "Copy text, save a photo or video to Photos, or share it.",
                            "Retry a message that failed to send, or delete it.",
                        ]),
                    ]),
        HelpArticle(id: "attachments", category: .gettingStarted, icon: "paperclip", title: "Photos, videos, files, voice notes and more",
                    summary: "Everything the + button and the mic can send.",
                    sections: [
                        HelpSection(paragraphs: ["Tap the + button beside the message field. Recent photos appear in a strip; tap one to send it, or long-press to select several and send them as an album."]),
                        HelpSection(heading: "From the tray", steps: [
                            "Camera: take a photo or video.",
                            "Photos and Video: pick from your library. Videos are compressed before upload.",
                            "File: send a document.",
                            "Contact or Location: share a contact card or where you are.",
                            "Vault: send a photo or video that can be viewed once, or that expires after 24 hours.",
                        ]),
                        HelpSection(paragraphs: ["Hold the microphone to record a voice note and release to send. While something uploads, a ring on the bubble shows progress; it spins while the file is being encrypted."]),
                    ]),
        HelpArticle(id: "share-extension", category: .gettingStarted, icon: "square.and.arrow.up", title: "Share into Sanchr from other apps",
                    summary: "Use the share sheet anywhere on your phone.",
                    sections: [
                        HelpSection(paragraphs: ["In Photos, Safari or any app, tap Share and choose Sanchr. Pick one or more conversations and send. If App Lock is on, you unlock first, just like in the app."]),
                    ]),

        // MARK: Security
        HelpArticle(id: "e2ee", category: .security, icon: "shield", title: "How end-to-end encryption works",
                    summary: "Keys live on your devices; servers relay ciphertext.",
                    sections: [
                        HelpSection(paragraphs: [
                            "Sanchr uses the Signal Protocol. When you first message someone, your phones agree on keys that only the two of them hold, and every message afterwards is encrypted with keys that change as you talk, so an old key cannot unlock later messages.",
                            "Photos, videos, files and voice notes are encrypted on your phone before upload. The server stores only the encrypted file, for a limited time, until the recipient downloads it.",
                            "Where possible Sanchr also hides who sent a message from the server (sealed sender): the envelope is addressed, but the sender is inside the encryption.",
                        ]),
                        HelpSection(heading: "What that means", paragraphs: [
                            "Nobody at Sanchr can read your messages, and we cannot hand them over. If you lose your phone and your backup key, the messages are gone; there is no server copy to recover.",
                        ]),
                    ], destination: .security),
        HelpArticle(id: "verify-code", category: .security, icon: "key", title: "Verify a contact's security code",
                    summary: "Confirm you are talking to the right person.",
                    sections: [
                        HelpSection(paragraphs: ["Each pair of contacts has a security code made from both of your keys. If it matches on both phones, nobody is sitting between you."]),
                        HelpSection(heading: "Steps", steps: [
                            "Open the conversation and tap the header to open Conversation Info.",
                            "Choose Security Code. You will see a QR code and a number.",
                            "In person, scan each other's code. Remotely, read the numbers aloud over a call and compare.",
                            "If they match, tap Mark as Verified. If a contact's code changes later, Sanchr tells you before your next message is sent, because it usually means they reinstalled or changed phones.",
                        ]),
                    ], destination: .security),
        HelpArticle(id: "registration-lock", category: .security, icon: "lock.rotation", title: "Registration Lock PIN",
                    summary: "Stop someone with your SIM from taking your account.",
                    sections: [
                        HelpSection(paragraphs: ["A Registration Lock adds a 6-digit PIN that anyone registering your number on a new phone must know, even if they receive your text messages."]),
                        HelpSection(heading: "Steps", steps: [
                            "Go to Settings → Security → Registration Lock.",
                            "Choose a 6-digit PIN you will remember and confirm it.",
                            "When you register on a new device, enter the PIN after the text-message code.",
                        ]),
                        HelpSection(paragraphs: ["Sanchr cannot reset the PIN for you; it is part of what protects the account."]),
                    ], destination: .registrationLock),
        HelpArticle(id: "app-lock", category: .security, icon: "faceid", title: "App Lock with Face ID, Touch ID or passcode",
                    summary: "Require an unlock when you return to the app.",
                    sections: [
                        HelpSection(heading: "Steps", steps: [
                            "Go to Settings → Security and turn on Biometric Lock, or pick a Screen Lock Timeout.",
                            "Choose how long the app can stay in the background before it locks again.",
                            "From then on the app asks for Face ID or Touch ID when you open it, and offers your passcode if biometrics fail.",
                        ]),
                        HelpSection(paragraphs: ["The share extension honours the same lock. App Lock protects the screen; your message database is separately encrypted on disk."]),
                    ], destination: .security),
        HelpArticle(id: "what-server-sees", category: .security, icon: "server.rack", title: "What Sanchr's servers can and cannot see",
                    summary: "The short list of account data that exists.",
                    sections: [
                        HelpSection(heading: "Held to run the service", steps: [
                            "Your phone number, which is your account identifier.",
                            "Identifiers for your devices and the tokens that wake the app for notifications.",
                            "Your public keys, so others can start an encrypted conversation with you.",
                            "Encrypted messages and media waiting to be delivered, then deleted.",
                        ]),
                        HelpSection(heading: "Never readable by us", steps: [
                            "Message text, media, calls.",
                            "Your name and profile photo.",
                            "Your address book: discovery uses blinded numbers.",
                            "Backups, which only your recovery key can open.",
                        ]),
                    ]),

        // MARK: Privacy
        HelpArticle(id: "sanchr-mode", category: .privacy, icon: "eye.slash", title: "Sanchr Mode",
                    summary: "Hidden previews, silent notifications, screenshots blocked.",
                    sections: [
                        HelpSection(paragraphs: ["Sanchr Mode is for times when your phone might be seen by others. Notifications stop showing message content and arrive silently, and screenshot protection turns on so the app switcher shows a blank card."]),
                        HelpSection(heading: "Steps", steps: [
                            "Go to Settings → Privacy.",
                            "Turn on Sanchr Mode. Turn it off the same way.",
                        ]),
                    ], destination: .privacy),
        HelpArticle(id: "presence", category: .privacy, icon: "checkmark.message", title: "Read receipts, online status and typing indicators",
                    summary: "Choose what others learn about your activity.",
                    sections: [
                        HelpSection(paragraphs: ["All three are on by default and each can be turned off in Settings → Privacy. They are mutual: with read receipts off you also stop seeing when others have read your messages."]),
                    ], destination: .privacy),
        HelpArticle(id: "disappearing", category: .privacy, icon: "timer", title: "Disappearing messages",
                    summary: "Messages that remove themselves after a time you set.",
                    sections: [
                        HelpSection(heading: "For one conversation", steps: [
                            "Open the conversation and tap the header.",
                            "Choose Disappearing Messages and pick a duration, or Off.",
                        ]),
                        HelpSection(heading: "For new conversations", steps: [
                            "Go to Settings → Chats and set Default Timer.",
                        ]),
                        HelpSection(paragraphs: ["The timer starts when a message is delivered. It applies on both phones, but a recipient can still screenshot or copy before it goes."]),
                    ], destination: .chatSettings),
        HelpArticle(id: "vault", category: .privacy, icon: "clock.arrow.circlepath", title: "Vault: view-once and self-destructing media",
                    summary: "Photos and videos that do not stay.",
                    sections: [
                        HelpSection(paragraphs: ["From the + tray choose Vault. A View Once photo or video can be opened one time by the recipient and then shows \"No longer available\". Vault media otherwise expires 24 hours after it is sent."]),
                        HelpSection(paragraphs: ["Vault items are encrypted like everything else and are included in encrypted backups. Secret Vault, under Settings → Privacy, keeps sensitive files and chats behind your lock."]),
                    ], destination: .privacy),
        HelpArticle(id: "block", category: .privacy, icon: "hand.raised", title: "Block someone",
                    summary: "Stop messages and calls from a contact.",
                    sections: [
                        HelpSection(heading: "Steps", steps: [
                            "Open the conversation, tap the header, and choose Block Contact.",
                            "To review or unblock, go to Settings → Privacy → Blocked contacts.",
                        ]),
                        HelpSection(paragraphs: ["A blocked contact is not told. Their messages and calls stop reaching you until you unblock them."]),
                    ], destination: .blockedContacts),

        // MARK: Chats & media
        HelpArticle(id: "auto-download", category: .chats, icon: "arrow.down.circle", title: "Media auto-download",
                    summary: "Save data by choosing what downloads on mobile.",
                    sections: [
                        HelpSection(paragraphs: ["Settings → Chats → Media Auto-Download lets you choose All media or Photos only for Wi-Fi, mobile data and roaming. Media that is not downloaded automatically shows a download button on the bubble."]),
                        HelpSection(paragraphs: ["Auto-save Received Media keeps downloaded photos and videos available offline in the app's storage."]),
                    ], destination: .chatSettings),
        HelpArticle(id: "chat-behaviour", category: .chats, icon: "text.cursor", title: "Link previews and the Return key",
                    summary: "Two small behaviours you can change.",
                    sections: [
                        HelpSection(paragraphs: ["Link Previews fetches a title and image for links you paste, from your phone, so the site sees your request but Sanchr does not. Turn it off in Settings → Chats if you prefer bare links.", "Enter Sends Message makes the Return key send instead of adding a line."]),
                    ], destination: .chatSettings),
        HelpArticle(id: "appearance", category: .chats, icon: "paintpalette", title: "Wallpapers, themes and dark mode",
                    summary: "For the whole app or one conversation.",
                    sections: [
                        HelpSection(paragraphs: ["Settings → Appearance sets the app theme: light, dark or follow the system. Each conversation can also have its own wallpaper and its own dark theme from Conversation Info → Wallpaper & Theme. Timestamps and the date chip adjust their colour to the wallpaper so they stay readable."]),
                    ], destination: .appearance),
        HelpArticle(id: "storage", category: .chats, icon: "internaldrive", title: "Storage and clearing space",
                    summary: "See what is using space and free it.",
                    sections: [
                        HelpSection(paragraphs: ["Settings → Storage & Data shows how much space encrypted images, videos and voice notes use. Clear Media Cache removes downloaded copies; anything still on the server can be downloaded again while it is available. Clear All Local Data removes messages from this phone."]),
                    ], destination: .storage),
        HelpArticle(id: "media-expired", category: .chats, icon: "photo.badge.exclamationmark", title: "\"Media expired\" on a photo or file",
                    summary: "Why it happens and what to do.",
                    sections: [
                        HelpSection(paragraphs: ["Encrypted media is kept on the server only for a limited time so that it can be delivered, then removed. If a photo, video, file or voice note was not downloaded in time, the bubble says it expired. Ask the sender to send it again; the new copy will download as usual."]),
                    ]),

        // MARK: Calls
        HelpArticle(id: "voice-calls", category: .calls, icon: "phone", title: "Voice calls",
                    summary: "Encrypted calls from any conversation.",
                    sections: [
                        HelpSection(heading: "Steps", steps: [
                            "Open the conversation and tap the phone icon in the header.",
                            "Allow microphone access the first time.",
                            "Incoming calls ring like phone calls, including on the lock screen, and appear in your call history.",
                        ]),
                        HelpSection(paragraphs: ["Call audio is end-to-end encrypted between the two phones. Video calling is being tested and will arrive in a later update."]),
                    ]),
        HelpArticle(id: "call-problems", category: .calls, icon: "phone.badge.waveform", title: "A call will not connect or has poor audio",
                    summary: "What to check.",
                    sections: [
                        HelpSection(steps: [
                            "Both phones need a working internet connection; Wi-Fi with a weak signal is often worse than mobile data.",
                            "Check Settings → Notifications: with call notifications off, incoming calls cannot ring.",
                            "If the microphone was denied, allow it in the iPhone Settings app under Sanchr.",
                            "Some networks block direct connections; Sanchr then relays the encrypted call, which can add delay.",
                        ]),
                    ], destination: .notifications),

        // MARK: Backups
        HelpArticle(id: "backup-enable", category: .backups, icon: "icloud.and.arrow.up", title: "Turn on encrypted backups",
                    summary: "Keep your history if you lose or change your phone.",
                    sections: [
                        HelpSection(heading: "Steps", steps: [
                            "Go to Settings → Chats → Backup & Recovery and tap Enable Backup.",
                            "Choose chats only, or chats and media. Media can be limited to Wi-Fi.",
                            "Set automatic backups, or back up when you choose with Back Up Now.",
                            "Write down your recovery key and keep it somewhere safe.",
                        ]),
                        HelpSection(paragraphs: ["Backups are encrypted on your phone before they are uploaded to your iCloud. Sanchr cannot open them."]),
                    ], destination: .backup),
        HelpArticle(id: "recovery-key", category: .backups, icon: "key.horizontal", title: "Your recovery key",
                    summary: "The only thing that opens a backup.",
                    sections: [
                        HelpSection(paragraphs: ["The recovery key is generated on your phone when you enable backups. View it or rotate it from Backup & Recovery. If you lose the key, the backup cannot be restored by anyone, including Sanchr; a rotated key only opens backups made after the rotation."]),
                    ], destination: .backup),
        HelpArticle(id: "restore", category: .backups, icon: "arrow.counterclockwise.circle", title: "Restore on a new phone",
                    summary: "Bring your history to a fresh install.",
                    sections: [
                        HelpSection(heading: "Steps", steps: [
                            "Install Sanchr and sign in with the same phone number. Your name and photo come back on their own.",
                            "When a backup is found, Sanchr offers to restore it right after sign-in. This is the moment to do it: once you start chatting, the offer is gone.",
                            "Enter your recovery key. Chats restore first; media downloads afterwards.",
                        ]),
                        HelpSection(paragraphs: ["You can also restore later from Backup & Recovery → Restore from Backup, which replaces what is on the phone."]),
                    ], destination: .backup),

        // MARK: Troubleshooting
        HelpArticle(id: "no-notifications", category: .troubleshooting, icon: "bell.slash", title: "Not getting notifications",
                    summary: "Permission, Focus modes and previews.",
                    sections: [
                        HelpSection(steps: [
                            "Open Settings → Notifications in Sanchr. If it says notifications are disabled, tap Turn On, or Settings to allow them in iOS.",
                            "Check that a Focus mode or Do Not Disturb is not silencing Sanchr.",
                            "With Sanchr Mode on, notifications are silent and show no preview by design.",
                            "Notifications carry no message content; the app fetches the message when you open it.",
                        ]),
                    ], destination: .notifications),
        HelpArticle(id: "not-sending", category: .troubleshooting, icon: "clock.badge.exclamationmark", title: "A message shows a clock or failed to send",
                    summary: "What the status icons mean.",
                    sections: [
                        HelpSection(paragraphs: ["A clock means the message is waiting for a connection. One tick means the server has it, two mean it was delivered, and blue ticks mean it was read. A message that fails shows a retry option when you long-press it."]),
                        HelpSection(paragraphs: ["If a contact's security code changed since you last spoke, Sanchr holds your message until you have seen the notice, so nothing is sent to an unverified new key by accident."]),
                    ]),
        HelpArticle(id: "no-code", category: .troubleshooting, icon: "message.badge", title: "The verification code did not arrive",
                    summary: "Resend, and what to check first.",
                    sections: [
                        HelpSection(steps: [
                            "Make sure the country and number on the previous screen are right; the screen shows the full number it sent to.",
                            "Wait for the resend timer, then tap Resend. Codes expire; the screen counts down.",
                            "Check that your phone can receive text messages and is not in airplane mode.",
                            "If your number has a Registration Lock from a previous install, you will be asked for the PIN after the code.",
                        ]),
                    ]),
        HelpArticle(id: "contact-names", category: .troubleshooting, icon: "person.text.rectangle", title: "A contact shows as \"Unknown\" or with a ~ name",
                    summary: "Where names come from.",
                    sections: [
                        HelpSection(paragraphs: ["Sanchr shows the name from your address book when it has one. Otherwise it shows the name the person chose, marked with ~, or their number. Save them in your address book and sync contacts again to see your name for them."]),
                    ]),
        HelpArticle(id: "free-space", category: .troubleshooting, icon: "externaldrive.badge.minus", title: "Sanchr is using a lot of space",
                    summary: "Clear caches without losing chats.",
                    sections: [
                        HelpSection(paragraphs: ["Settings → Storage & Data → Clear Media Cache removes downloaded photos, videos and voice notes but keeps your messages. Turning Auto-save Received Media off in Settings → Chats stops the cache growing as fast."]),
                    ], destination: .storage),

        // MARK: Account
        HelpArticle(id: "delete-account", category: .account, icon: "trash", title: "Delete your account",
                    summary: "The only way to leave, and what it erases.",
                    sections: [
                        HelpSection(paragraphs: ["Sanchr has no sign-out: the account is tied to your phone number on this device. Deleting it removes your account, keys, devices, queued messages and stored media from the servers, and wipes the app's data on this phone. Messages already delivered to other people stay with them."]),
                        HelpSection(heading: "Steps", steps: [
                            "Go to Settings → Security → Delete Account.",
                            "Read what will be erased and confirm.",
                        ]),
                    ], destination: .security),
        HelpArticle(id: "change-number", category: .account, icon: "arrow.triangle.2.circlepath", title: "Change your phone number",
                    summary: "Not automatic yet.",
                    sections: [
                        HelpSection(paragraphs: ["Moving an account to a new number is not supported in this version. Back up your chats, delete the account, then register with the new number and restore from the backup. Your contacts will need to verify your new security code."]),
                    ], destination: .backup),
        HelpArticle(id: "sessions", category: .account, icon: "desktopcomputer", title: "Active sessions and devices",
                    summary: "See where your account is signed in.",
                    sections: [
                        HelpSection(paragraphs: ["Settings → Security → Active Sessions lists the devices registered to your number. One phone per account is the norm; if you see a device you do not recognise, change your Registration Lock PIN and contact support."]),
                    ], destination: .security),
    ]
}
