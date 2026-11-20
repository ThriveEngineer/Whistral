//
//  UpdateChecker.swift
//  Whistral
//
//  Checks GitHub Releases for new Whistral versions.
//  Provides update info and actions to open the download or release page.
//

import AppKit
import Combine
import Foundation

// MARK: - Update Info

struct AppUpdateInfo: Equatable {
    let version: String
    let htmlURL: URL
    let downloadURL: URL?
    let releaseName: String
    let releaseNotes: String?
}

// MARK: - Update Checker

@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    private static let repo = "ThriveEngineer/Whistral"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    @Published private(set) var availableUpdate: AppUpdateInfo?
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var checkError: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
    }

    // MARK: - Check

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil

        Task {
            do {
                var request = URLRequest(url: Self.releasesURL)
                request.timeoutInterval = 10
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.setValue("Whistral-App", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw UpdateError.badResponse(code)
                }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

                guard !release.prerelease, !release.draft else {
                    self.isChecking = false
                    self.lastCheckDate = Date()
                    return
                }

                let remoteVersion = Self.normalizeVersion(release.tagName)
                let localVersion = Self.normalizeVersion(self.currentVersion)

                if Self.isVersion(remoteVersion, higherThan: localVersion) {
                    let zipAsset = release.assets.first { $0.name.hasSuffix(".zip") }
                    let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadUrl) }
                    let htmlURL = URL(string: release.htmlUrl) ?? Self.releasesURL

                    self.availableUpdate = AppUpdateInfo(
                        version: remoteVersion,
                        htmlURL: htmlURL,
                        downloadURL: downloadURL,
                        releaseName: release.name ?? "Whistral \(remoteVersion)",
                        releaseNotes: release.body
                    )
                } else {
                    self.availableUpdate = nil
                }

                self.lastCheckDate = Date()
                self.isChecking = false

            } catch {
                self.checkError = error.localizedDescription
                self.isChecking = false
                self.lastCheckDate = Date()
            }
        }
    }

    // MARK: - Actions

    func openDownload() {
        guard let update = availableUpdate else { return }
        let targetURL = update.downloadURL ?? update.htmlURL
        NSWorkspace.shared.open(targetURL)
    }

    func openReleaseNotes() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.htmlURL)
    }

    // MARK: - Version Comparison

    static func normalizeVersion(_ string: String) -> String {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// Returns true if `v1` is strictly newer/higher than `v2`.
    static func isVersion(_ v1: String, higherThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        let count = max(parts1.count, parts2.count)
        for i in 0..<count {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return "Failed to check for updates (server returned \(code))."
            }
        }
    }
}

// MARK: - GitHub API Decodable Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case body
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
