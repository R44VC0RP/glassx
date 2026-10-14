import CommonCrypto
import Foundation
import Security
import SQLite3

/// A Chromium browser profile that is signed in to x.com.
struct BrowserSession: Identifiable, Hashable {
    var id: String { cookiesFile.path }
    var browser: String
    var profileName: String
    var cookiesFile: URL
    var keychainService: String
    var keychainAccount: String

    var title: String { profileName == "Default" ? browser : "\(browser) — \(profileName)" }
}

/// Copies the x.com session out of a Chromium-based browser (Arc, Chrome, Helium, Brave, Edge…).
///
/// Chromium on macOS encrypts cookie values with AES-128-CBC using a key derived (PBKDF2-