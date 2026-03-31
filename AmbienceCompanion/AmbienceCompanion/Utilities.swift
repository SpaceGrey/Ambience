//
//  Utilities.swift
//  AmbienceCompanion
//
//  Created by Shuhari on 2024/10/12.
//

import Foundation
import MusicKit

class MusicService: ObservableObject {
    @Published var isRetrievingRecommendations = false
    @Published var recommendation: [UserMusicItem] = []

    init() {
        Task { @MainActor in
            if MusicAuthorization.currentStatus != .authorized {
                let status = await MusicAuthorization.request()
                guard status == .authorized else { return }
            }

            isRetrievingRecommendations = true
            defer { isRetrievingRecommendations = false }

            do {
                recommendation = try await fetchRecommendations()
            } catch {
                print("Failed to load recommendations: \(error)")
            }
        }
    }

    private func fetchRecommendations() async throws -> [UserMusicItem] {
        let collections = try await MusicPersonalRecommendationsRequest().response().recommendations
        return collections.flatMap { recommendation in
            recommendation.albums.map { $0.toUserMusicItem() }
                + recommendation.playlists.map { $0.toUserMusicItem() }
        }
    }
}
