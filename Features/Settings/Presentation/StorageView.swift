import SwiftUI

/// Storage and data management screen.
/// Matches Figma: storage-data-screen.
struct StorageView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var autoDownloadPhotos = true
    @State private var autoDownloadVideos = false
    @State private var autoDownloadDocuments = true

    var body: some View {
        List {
            Section("Storage") {
                HStack {
                    Text("Messages")
                    Spacer()
                    Text("--")
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                HStack {
                    Text("Media")
                    Spacer()
                    Text("--")
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                HStack {
                    Text("Vault")
                    Spacer()
                    Text("--")
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Auto-download") {
                Toggle("Photos", isOn: $autoDownloadPhotos)
                    .tint(.sanchrPrimary)
                Toggle("Videos", isOn: $autoDownloadVideos)
                    .tint(.sanchrPrimary)
                Toggle("Documents", isOn: $autoDownloadDocuments)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section {
                Button(role: .destructive) {
                    // TODO: Clear media cache
                } label: {
                    Text("Clear media cache")
                }

                Button(role: .destructive) {
                    // TODO: Clear all data
                } label: {
                    Text("Clear all local data")
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage & Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}
