//
//  PackShareSheet.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import SwiftUI
import UIKit

/// `UIActivityViewController`, because `ShareLink` is iOS 16 and this package
/// supports 15. Shares a file URL rather than the JSON as text: the activity
/// list is then the useful one — Files, AirDrop, Slack — and the pack arrives
/// with its own name instead of as an untitled blob.
struct PackShareSheet: UIViewControllerRepresentable {

    let urls: [URL]

    init(url: URL) { self.urls = [url] }

    /// A run shares as several files at once — the manifest and its
    /// screenshots. Zipping them would need a dependency this package refuses
    /// to take, and AirDrop and Files both accept a multi-file share happily.
    init(urls: [URL]) { self.urls = urls }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nothing to update: the sheet is rebuilt for each URL.
    }
}
#endif
