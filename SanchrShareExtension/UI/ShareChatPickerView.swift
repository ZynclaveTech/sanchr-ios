import SwiftUI
import SanchrShared

/// Multi-select chat picker for the share extension. Reads the shared
/// App Group SQLCipher database through the extension-safe
/// `LocalDatabase.openForExtension()` factory and renders a
/// `ShareChatSummary` list with a horizontal "recents" strip, a search
/// box, and a vertical results list.
struct ShareChatPickerView: View {

    let payload: SharePayload
    let onCancel: () -> Void
    let onNext: ([ShareChatSummary]) -> Void

    @State private var summaries: [ShareChatSummary] = []
    @State private var selectedIds: Set<String> = []
    @State private var query: String = ""
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private var filtered: [ShareChatSummary] {
        guard !query.isEmpty else { return summaries }
        return summaries.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") {
                            onNext(summaries.filter { selectedIds.contains($0.id) })
                        }
                        .disabled(selectedIds.isEmpty)
                        .tint(SanchrColors.primary)
                    }
                }
                .task { await load() }
        }
    }

    private var navigationTitle: String {
        selectedIds.isEmpty ? "Share to" : "\(selectedIds.count) selected"
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(SanchrColors.warning)
                Text("Couldn't load chats")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))

        case .loaded:
            if summaries.isEmpty {
                Text("No chats yet. Start a conversation in Sanchr first.")
                    .font(.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
            } else {
                loadedContent
            }
        }
    }

    private var loadedContent: some View {
        VStack(spacing: 0) {
            recentsStrip
            Divider()
            searchBar
            List {
                ForEach(filtered) { summary in
                    ShareChatRow(
                        summary: summary,
                        isSelected: selectedIds.contains(summary.id)
                    ) {
                        toggle(summary.id)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var recentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(summaries.prefix(12))) { summary in
                    recentsChip(for: summary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func recentsChip(for summary: ShareChatSummary) -> some View {
        let selected = selectedIds.contains(summary.id)
        return Button {
            toggle(summary.id)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selected ? SanchrColors.primary : Color(uiColor: .systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(String(summary.title.prefix(1)).uppercased())
                            .font(SanchrTypography.scaled(size: 22, weight: .semibold))
                            .foregroundColor(selected ? .white : SanchrExportColors.textSecondary)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(SanchrColors.primary)
                                .background(Circle().fill(Color(uiColor: .systemBackground)))
                        }
                    }
                Text(summary.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 64)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(12)
        .background(Color(uiColor: .systemGray6))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func load() async {
        _ = payload  // payload is only used downstream; referenced to silence unused-warning
        do {
            let db = try LocalDatabase.openForExtension()
            let rows = try await db.fetchShareChatSummaries()
            await MainActor.run {
                self.summaries = rows
                self.loadState = .loaded
            }
        } catch {
            await MainActor.run {
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }
}
