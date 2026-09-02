import SwiftUI

/// Width of the surface message bubbles are laid out in.
///
/// Bubbles size themselves against this rather than `UIScreen.main.bounds`,
/// which is the whole screen: wrong in a split view, wrong in a sheet, and
/// stale across a rotation until something else redrew the row.
private struct MessageAvailableWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var messageAvailableWidth: CGFloat? {
        get { self[MessageAvailableWidthKey.self] }
        set { self[MessageAvailableWidthKey.self] = newValue }
    }
}
