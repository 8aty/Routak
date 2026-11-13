import SwiftUI
import UIKit

/// A file ready to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for files created on demand (ShareLink needs the file up front).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// Presents the share sheet for `file` while it's set.
    func shareSheet(_ file: Binding<SharedFile?>) -> some View {
        sheet(item: file) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}
