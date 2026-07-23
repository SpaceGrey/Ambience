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
    
    /// Resolves a music item URL to the raw HLS stream URL (m3u8), without downloading.
    ///
    /// Use this when you need the remote stream URL directly (e.g. for export via
    /// `AVAssetExportSession`), rather than the locally cached `.movpkg`.
    public static func resolveHLSURL(
        from musicItemSourceURL: URL,
        storefrontPolicy: StorefrontChoosePolicy = .tryBoth
    ) async throws -> URL {
        AmbienceLog.info(
            "resolveHLSURL started",
            metadata: [
                "source_url": musicItemSourceURL.absoluteString,
                "storefront_policy": String(describing: storefrontPolicy),
                "region_first": String(regionFirst),
            ]
        )

        do {
            let url = try await resolveURL(
                from: musicItemSourceURL,
                storefrontPolicy: storefrontPolicy,
                resolve: { pageURL in
                    let html = try await HTMLFetcher.fetchHTMLContent(from: pageURL)
                    return try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: html)
                }
            )
            AmbienceLog.info(
                "resolveHLSURL succeeded",
                metadata: [
                    "source_url": musicItemSourceURL.absoluteString,
                    "hls_url": url.absoluteString,
                ]
            )
            return url
        } catch {
            AmbienceLog.error(
                "resolveHLSURL failed",
                metadata: [
                    "source_url": musicItemSourceURL.absoluteString,
                    "error": String(describing: error),
                ]
            )
            throw error
        }
    }

    /// Fetches the ambience asset configuration file URL for a given music item source URL
    public static func fetchAmbienceAsset(
        from musicItemSourceURL: URL,
        storefrontPolicy: StorefrontChoosePolicy = .tryBoth
    ) async throws -> URL {
        AmbienceLog.info(
            "fetchAmbienceAsset started",
            metadata: [
                "source_url": musicItemSourceURL.absoluteString,
                "storefront_policy": String(describing: storefrontPolicy),
                "region_first": String(regionFirst),
                "target_bitrate": String(format: "%.0f", targetBitrate),
                "cache_limit": String(cacheLimit),
            ]
        )

        do {
            let url = try await resolveURL(
                from: musicItemSourceURL,
                storefrontPolicy: storefrontPolicy,
                resolve: { pageURL in
                    try await HLSAssetManager.shared.getAsset(from: pageURL)
                }
            )
            AmbienceLog.info(
                "fetchAmbienceAsset succeeded",
                metadata: [
                    "source_url": musicItemSourceURL.absoluteString,
                    "asset_url": url.absoluteString,
                    "is_local": String(url.isFileURL),
                ]
            )
            return url
        } catch {
            AmbienceLog.error(
                "fetchAmbienceAsset failed",
                metadata: [
                    "source_url": musicItemSourceURL.absoluteString,
                    "error": String(describing: error),
                ]
            )
            throw error
        }
    }

    // MARK: - Private

    private static func resolveURL(
        from musicItemSourceURL: URL,
        storefrontPolicy: StorefrontChoosePolicy,
        resolve: @escaping (URL) async throws -> URL
    ) async throws -> URL {
        let adjustedURL = try await URLAdjuster.adjustURLForRegion(musicItemSourceURL)
        let resolveWithRecovery: (URL) async throws -> URL = { pageURL in
            try await resolveWithStorefrontRedirectRecovery(from: pageURL, resolve: resolve)
        }

        switch storefrontPolicy {
        case .followAccount:
            AmbienceLog.debug(
                "Using account storefront only",
                metadata: ["url": musicItemSourceURL.absoluteString]
            )
            return try await resolveWithRecovery(musicItemSourceURL)
        case .followRegion:
            AmbienceLog.debug(
                "Using region storefront only",
                metadata: ["url": adjustedURL.absoluteString]
            )
            return try await resolveWithRecovery(adjustedURL)
        case .tryBoth:
            if regionFirst {
                AmbienceLog.debug(
                    "tryBoth: attempting region storefront first",
                    metadata: [
                        "primary_url": adjustedURL.absoluteString,
                        "fallback_url": musicItemSourceURL.absoluteString,
                    ]
                )
                do {
                    return try await resolveWithRecovery(adjustedURL)
                } catch AmbienceError.redirectedToHomepage(let detected) {
                    // Recovery already tried; if URLs differ, attempt the other policy URL.
                    guard adjustedURL != musicItemSourceURL else {
                        throw AmbienceError.redirectedToHomepage(detectedStorefront: detected)
                    }
                    AmbienceLog.warning(
                        "Region storefront redirected; falling back to account storefront",
                        metadata: [
                            "failed_url": adjustedURL.absoluteString,
                            "fallback_url": musicItemSourceURL.absoluteString,
                            "detected_storefront": detected ?? "unknown",
                        ]
                    )
                    let res = try await resolveWithRecovery(musicItemSourceURL)
                    regionFirst = false
                    return res
                }
            } else {
                AmbienceLog.debug(
                    "tryBoth: attempting account storefront first",
                    metadata: [
                        "primary_url": musicItemSourceURL.absoluteString,
                        "fallback_url": adjustedURL.absoluteString,
                    ]
                )
                do {
                    return try await resolveWithRecovery(musicItemSourceURL)
                } catch AmbienceError.redirectedToHomepage(let detected) {
                    guard adjustedURL != musicItemSourceURL else {
                        throw AmbienceError.redirectedToHomepage(detectedStorefront: detected)
                    }
                    AmbienceLog.warning(
                        "Account storefront redirected; falling back to region storefront",
                        metadata: [
                            "failed_url": musicItemSourceURL.absoluteString,
                            "fallback_url": adjustedURL.absoluteString,
                            "detected_storefront": detected ?? "unknown",
                        ]
                    )
                    let res = try await resolveWithRecovery(adjustedURL)
                    regionFirst = true
                    return res
                }
            }
        }
    }

    /// When Apple Music 302-redirects a catalog page to a regional homepage (geo mismatch),
    /// rewrite the catalog URL to that storefront and retry once.
    ///
    /// This covers the common case where MusicKit/`Locale` report e.g. `us`, but the
    /// network edge is in another region (e.g. China) and web pages only serve under `/cn/`.
    private static func resolveWithStorefrontRedirectRecovery(
        from pageURL: URL,
        resolve: @escaping (URL) async throws -> URL
    ) async throws -> URL {
        do {
            return try await resolve(pageURL)
        } catch AmbienceError.redirectedToHomepage(let detectedStorefront) {
            guard let detectedStorefront,
                  let correctedURL = StorefrontURLRewriter.replacingStorefront(
                    in: pageURL,
                    with: detectedStorefront
                  ),
                  correctedURL != pageURL
            else {
                AmbienceLog.error(
                    "Storefront redirect recovery unavailable",
                    metadata: [
                        "url": pageURL.absoluteString,
                        "detected_storefront": detectedStorefront ?? "unknown",
                    ]
                )
                throw AmbienceError.redirectedToHomepage(detectedStorefront: detectedStorefront)
            }

            AmbienceLog.warning(
                "Retrying with redirect-detected storefront",
                metadata: [
                    "original_url": pageURL.absoluteString,
                    "corrected_url": correctedURL.absoluteString,
                    "detected_storefront": detectedStorefront,
                    "original_storefront": StorefrontURLRewriter.storefront(in: pageURL) ?? "unknown",
                ]
            )

            return try await resolve(correctedURL)
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
            AmbienceLog.debug(
                "URL region adjustment skipped",
                metadata: [
                    "url": url.absoluteString,
                    "account_storefront": amCode,
                    "device_region": deviceRegionIdentifier ?? "unknown",
                ]
            )
            return url
        }
        
        let adjusted = try replaceStorefront(in: url, from: amCode, to: deviceRegionIdentifier)
        AmbienceLog.info(
            "URL adjusted for device region",
            metadata: [
                "original_url": url.absoluteString,
                "adjusted_url": adjusted.absoluteString,
                "account_storefront": amCode,
                "device_region": deviceRegionIdentifier,
            ]
        )
        return adjusted
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
