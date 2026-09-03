import SanchrShared
import SwiftUI

/// Searchable list of every country, replacing a ten-entry menu.
struct CountryPickerView: View {
    @Binding var selection: PhoneCountry
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [PhoneCountry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return PhoneCountry.all }
        let digits = trimmed.filter(\.isNumber)
        return PhoneCountry.all.filter { country in
            country.name.localizedCaseInsensitiveContains(trimmed)
                || country.region.localizedCaseInsensitiveContains(trimmed)
                || (!digits.isEmpty && country.callingDigits.hasPrefix(digits))
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { country in
                Button {
                    selection = country
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag)
                        Text(country.name)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Spacer()
                        Text(country.callingCode)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .monospacedDigit()
                        if country == selection {
                            Image(systemName: "checkmark")
                                .foregroundColor(SanchrColors.primary)
                        }
                    }
                }
                .accessibilityLabel("\(country.name), \(country.callingCode)")
                .accessibilityAddTraits(country == selection ? .isSelected : [])
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Country or code")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
