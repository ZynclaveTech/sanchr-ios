import SwiftUI
import SanchrShared

/// Conversation picker for the "Forward" message action.
///
/// Tapping a row used to forward immediately. Every row in the list was one
/// mis-tap away from sending a private message to the wrong person, and a
/// forward cannot be recalled — it is sent and delivered. A tap selects now,
/// and a footer says who it is going to, which is the step Signal's
/// `ApprovalFooterView` exists to provide.
///
/// Several destinations at once, as Signal allows: forwarding the same
/// message to three people was three trips through this sheet.
struct MessageForwardDestinationPicker: View {
    let localDatabase: LocalDatabaseProtocol
    let onConversationsPicked: (_ conversations: [(id: String, name: String)]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: [String] = []

    private var selected: [Conversation] {
        selectedIDs.compactMap { id in conversations.first { $0.id == id } }
    }

    @State private var conversations: [Conversation] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Recents, then contacts, then groups — Signal's order, and the order
    /// that puts the answer first: a forward almost always goes to someone you
    /// were just talking to, and a single list of every conversation made that
    /// a scroll.
    ///
    /// Searching collapses to one list. Sections are there to shorten the path
    /// to a likely destination; once a name has been typed, the likely
    /// destination is whatever matches it.
    static func sections(
        for conversations: [Conversation],
        searching: Bool,
        recentLimit: Int = 5
    ) -> [(title: String?, items: [Conversation])] {
        guard !searching else {
            return [(nil, conversations)]
        }
        let recents = Array(conversations.prefix(recentLimit))
        let recentIDs = Set(recents.map(\.id))
        let rest = conversations.filter { !recentIDs.contains($0.id) }
        let byName: (Conversation, Conversation) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return [
            ("Recent", recents),
            ("Contacts", rest.filter { $0.type == .oneToOne }.sorted(by: byName)),
            ("Groups", rest.filter { $0.type == .group }.sorted(by: byName))
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load conversations")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(loadError)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredConversations.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No conversations" : "No matches",
                        systemImage: "message",
                        description: Text(
                            searchText.isEmpty
                                ? "Start a chat first."
                                : "Try a different name."
                        )
                    )
                } else {
                    List {
                        ForEach(
                            Self.sections(
                                for: filteredConversations,
                                searching: !searchText.isEmpty
                            ),
                            id: \.title
                        ) { section in
                            Section {
                                ForEach(section.items, id: \.id) { conversation in
                                    Button {
                                        toggle(conversation.id)
                                    } label: {
                                        ForwardConversationRow(
                                            conversation: conversation,
                                            isSelected: selectedIDs.contains(conversation.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(
                                        EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                                    )
                                    .listRowBackground(SanchrExportColors.background)
                                }
                            } header: {
                                if let title = section.title {
                                    SanchrSectionEyebrow(title: title)
                                        .textCase(nil)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(SanchrExportColors.background)
                    .searchable(text: $searchText, prompt: "Search conversations")
                }
            }
            .safeAreaInset(edge: .bottom) { approvalFooter }
            // The footer declares a slide transition; without an animation
            // on the state that inserts it, it just popped in.
            .animation(.easeInOut(duration: 0.22), value: selected.isEmpty)
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .background(SanchrExportColors.background.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .task {
            await loadConversations()
        }
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
    }

    /// Names the destinations and holds the send.
    @ViewBuilder
    private var approvalFooter: some View {
        if !selected.isEmpty {
            HStack(spacing: 12) {
                Text(Self.namesText(for: selected.map(\.displayName)))
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button {
                    onConversationsPicked(selected.map { ($0.id, $0.displayName) })
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            LinearGradient(
                                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    selected.count == 1
                        ? "Send to \(selected[0].displayName)"
                        : "Send to \(selected.count) conversations"
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
            .transition(.move(edge: .bottom))
        }
    }

    /// "Ravi", "Ravi and Meera", "Ravi, Meera and 2 others" — the names
    /// matter more than the count when what is being confirmed is who sees a
    /// message they were not sent.
    static func namesText(for names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let others = names.count - 2
            return "\(names[0]), \(names[1]) and \(others) other\(others == 1 ? "" : "s")"
        }
    }

    private func loadConversations() async {
        do {
            let all = try await localDatabase.fetchConversations()
            conversations = all.sorted { $0.lastActivityAt > $1.lastActivityAt }
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Row

private struct ForwardConversationRow: View {
    let conversation: Conversation
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: conversation.displayName))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)
                if let preview = lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            // A chevron promises that tapping opens something. Tapping picks
            // a destination, and the row has to say whether it is picked.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(
                    isSelected ? SanchrColors.primary : SanchrExportColors.textTertiary
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conversation.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var lastMessagePreview: String? {
        guard let last = conversation.lastMessage else { return nil }
        switch last.content {
        case .text(let body): return body
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "File"
        case .location: return "Location"
        case .contact: return "Contact"
        case .system: return nil
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").prefix(2)
        let result = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return result.isEmpty ? "?" : result
    }
}
