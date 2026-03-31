//
//  AmbienceService.swift
//  Ambience
//
//  Created by Shuhari on 2024/10/12.
//  Copyright © 2024 Shuhari. All rights reserved.
//
//  This file is part of the Ambience package.
//
//  Description:
//  AmbienceService provides functionality for fetching and processing ambience
//  artwork assets associated with Apple Music items. It includes methods for
//  URL adjustment, HTML content fetching, and ambience artwork URL extraction.

import Foundation
import Kanna
import MusicKit
@_exported import AmbienceCore

/// Main class for handling Ambience-related operations
public enum AmbienceService {
    /// set the cache limit of ambience assets
    public static var cacheLimit = 100
    /// Minimum acceptable average bitrate (bps) when selecting an HLS variant.
    /// The downloader picks the lowest-bitrate stream that still meets this threshold,
    /// so set this to the quality floor you want. Defaults to 4 Mbps, which targets
    /// 1080×1080 on Apple's ambient video streams.
    public static var targetBitrate: Double = 4_000_000

    public typealias AmbienceError = AmbienceCore.AmbienceError
    
    /// Policy for choosing which storefront to use when fetching ambience assets
    public enum StorefrontChoosePolicy {
        /// Use only the account's storefront (original URL without region adjustment)
        case followAccount
        /// Use only the device's region storefront (URL adjusted to match device region)
        case followRegion
        /// Try both storefronts with fallback mechanism, controlled by `regionFirst` property
        case tryBoth
    }
    
    /// If true, the region-adjusted URL will be tried first, otherwise the account URL will be tried first
    private static var regionFirst: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "Ambience_regionFirst")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Ambience_regionFirst")
        }
    }
    
    /// Fetches the ambience asset configuration file URL for a given music item source URL
    /// - Parameters:
    ///   - musicItemSourceURL: The URL of the music item source
    ///   - storefrontPolicy: The policy for choosing which storefront to use (default: .tryBoth)
    /// - Returns: The URL of the ambience asset configuration file
    /// - Throws: `AmbienceError` if any error occurs during the process
    ///
    /// - Note: The `storefrontPolicy` parameter is crucial in certain scenarios where the user's physical location
    ///   doesn't match their Apple Music subscription region. For example:
    ///
    ///   A user located in mainland China might have an Apple Music subscription registered in the United States.
    ///   In this case, when trying to access certain playlists (especially Apple Music's official curated playlists
    ///   like Heavy Rotation Mix), the default behavior might fail to retrieve the Ambience content.
    ///
    ///   The `regionFirst` property controls the priority when using `.tryBoth` policy:
    ///   - If `regionFirst` is `true`, it tries region-adjusted URL first, then falls back to account URL
    ///   - If `regionFirst` is `false`, it tries account URL first, then falls back to region-adjusted URL
    ///
    ///   Example usage:
    ///   ```
    ///   // Try both account and region storefronts (default behavior)
    ///   let ambienceURL = try await AmbienceService.fetchAmbienceAsset(from: musicItemURL)
    ///
    ///   // Only use account storefront
    ///   let accountOnlyURL = try await AmbienceService.fetchAmbienceAsset(from: musicItemURL, storefrontPolicy: .followAccount)
    ///
    ///   // Only use region storefront
    ///   let regionOnlyURL = try await AmbienceService.fetchAmbienceAsset(from: musicItemURL, storefrontPolicy: .followRegion)
    ///   ```
    /// Resolves a music item URL to the raw HLS stream URL (m3u8), without downloading.
    ///
    /// Use this when you need the remote stream URL directly (e.g. for export via
    /// `AVAssetExportSession`), rather than the locally cached `.movpkg`.
    public static func resolveHLSURL(
        from musicItemSourceURL: URL,
        storefrontPolicy: StorefrontChoosePolicy = .tryBoth
    ) async throws -> URL {
        let adjustedURL = try await URLAdjuster.adjustURLForRegion(musicItemSourceURL)

        let fetchHLS: (URL) async throws -> URL = { pageURL in
            let html = try await HTMLFetcher.fetchHTMLContent(from: pageURL)
            return try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: html)
        }

        switch storefrontPolicy {
        case .followAccount:
            return try await fetchHLS(musicItemSourceURL)
        case .followRegion:
            return try await fetchHLS(adjustedURL)
        case .tryBoth:
            if regionFirst {
                do { return try await fetchHLS(adjustedURL) }
                catch AmbienceError.redirectedToHomepage {
                    let res = try await fetchHLS(musicItemSourceURL)
                    regionFirst = false
                    return res
                }
            } else {
                do { return try await fetchHLS(musicItemSourceURL) }
                catch AmbienceError.redirectedToHomepage {
                    let res = try await fetchHLS(adjustedURL)
                    regionFirst = true
                    return res
                }
            }
        }
    }

    /// Fetches the ambience asset configuration file URL for a given music item source URL
    public static func fetchAmbienceAsset(
        from musicItemSourceURL: URL,
        storefrontPolicy: StorefrontChoosePolicy = .tryBoth
    ) async throws -> URL {
        let adjustedURL = try await URLAdjuster.adjustURLForRegion(musicItemSourceURL)
        switch storefrontPolicy {
        case .followAccount:
            return try await HLSAssetManager.shared.getAsset(from: musicItemSourceURL)
        case .followRegion:
            return try await HLSAssetManager.shared.getAsset(from: adjustedURL)
        case .tryBoth:
            if regionFirst {
                do {
                    return try await HLSAssetManager.shared.getAsset(from: adjustedURL)
                } catch AmbienceError.redirectedToHomepage {
                    let res = try await HLSAssetManager.shared.getAsset(from: musicItemSourceURL)
                    regionFirst = false
                    return res
                }
            } else {
                do {
                    return try await HLSAssetManager.shared.getAsset(from: musicItemSourceURL)
                } catch AmbienceError.redirectedToHomepage {
                    let res = try await HLSAssetManager.shared.getAsset(from: adjustedURL)
                    regionFirst = true
                    return res
                }
            }
        }
    }
}

/// Struct responsible for adjusting URLs based on region
private enum URLAdjuster {
    
    /// Adjusts the given URL to match the device's region if necessary
    /// - Parameter url: The original URL to adjust
    /// - Returns: An adjusted URL that matches the device's region
    /// - Throws: An error if the URL adjustment fails
    static func adjustURLForRegion(_ url: URL) async throws -> URL {
        let deviceRegionIdentifier: String?
        if #available(iOS 16, *) {
            deviceRegionIdentifier = Locale.current.region?.identifier.lowercased()
        } else {
            deviceRegionIdentifier = Locale.current.regionCode?.lowercased()
        }
        let amCode = try await MusicDataRequest.currentCountryCode
        
        guard let deviceRegionIdentifier = deviceRegionIdentifier, amCode != deviceRegionIdentifier else {
            return url
        }
        
        return try replaceStorefront(in: url, from: amCode, to: deviceRegionIdentifier)
    }
    
    /// Replaces the storefront in the given URL
    /// - Parameters:
    ///   - url: The original URL
    ///   - originalStorefront: The current storefront code in the URL
    ///   - newStorefront: The new storefront code to replace with
    /// - Returns: A URL with the updated storefront
    /// - Throws: An error if the URL manipulation fails
    private static func replaceStorefront(
        in url: URL,
        from originalStorefront: String,
        to newStorefront: String?
    ) throws -> URL {
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AmbienceService.AmbienceError.invalidURL
        }
        
        guard let newStorefront = newStorefront else {
            return url
        }
        
        var pathComponents = url.pathComponents
        pathComponents.removeFirst()
        
        if let index = pathComponents.firstIndex(of: originalStorefront) {
            pathComponents[index] = newStorefront
        }
        
        urlComponents.path = "/" + pathComponents.joined(separator: "/")
        
        guard let adjustedURL = urlComponents.url else {
            throw AmbienceService.AmbienceError.invalidURL
        }
        
        return adjustedURL
    }
}

