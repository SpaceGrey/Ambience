//
//  ContentView.swift
//  AmbienceCompanion
//
//  Created by Shuhari on 2024/10/12.
//

import Ambience
import MusicKit
import Photos
import SwiftUI

// MARK: - Models

struct PresentedItem: Identifiable, Hashable {
    let id = UUID()
    let musicItem: UserMusicItem?
    let url: URL

    static func == (lhs: PresentedItem, rhs: PresentedItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var musicService = MusicService()
    @Binding var deepLinkURL: URL?

    @State private var searchText = ""
    @State private var searchResults: [UserMusicItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var presentedItem: PresentedItem?
    @Namespace private var heroNamespace

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !searchResults.isEmpty {
                        searchResultsSection
                    } else if searchText.isEmpty {
                        headerSection
                        recommendationSection
                    } else if isSearching {
                        centeredPlaceholder {
                            ProgressView()
                            Text("Searching…")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        centeredPlaceholder {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 32))
                                .foregroundStyle(.quaternary)
                            Text("No Results")
                                .font(.headline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ambience")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Albums, playlists, artists…")
            #else
            .searchable(text: $searchText, prompt: "Albums, playlists, artists…")
            #endif
            .onChange(of: searchText) { _ in performSearch() }
            .fullScreenCover(item: $presentedItem) { presented in
                if #available(iOS 18.0, *), let musicItem = presented.musicItem {
                    NavigationStack { PlayerView(item: presented) }
                        .navigationTransition(.zoom(sourceID: musicItem.id, in: heroNamespace))
                } else {
                    NavigationStack { PlayerView(item: presented) }
                }
            }
            .onChange(of: deepLinkURL) { url in
                guard let url else { return }
                deepLinkURL = nil
                presentedItem = PresentedItem(musicItem: nil, url: url)
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "music.quarternote.3")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Search for albums or playlists above, or share a link from ")
                + Text("Apple Music")
                    .bold()
                + Text(" using the share sheet.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Results")
                .font(.title3.bold())

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(searchResults) { item in
                    MusicItemCard(item: item)
                        .matchedTransitionSourceIfAvailable(id: item.id, in: heroNamespace)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let url = item.url else { return }
                            presentedItem = PresentedItem(musicItem: item, url: url)
                        }
                }
            }
        }
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("For You")
                .font(.title3.bold())

            if musicService.isRetrievingRecommendations {
                centeredPlaceholder {
                    ProgressView()
                    Text("Loading recommendations…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            } else if musicService.recommendation.isEmpty {
                centeredPlaceholder {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("No Recommendations")
                        .font(.headline)
                        .foregroundStyle(.tertiary)
                    Text("Grant Apple Music access to see personalized recommendations.")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(musicService.recommendation) { item in
                        MusicItemCard(item: item)
                            .matchedTransitionSourceIfAvailable(id: item.id, in: heroNamespace)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let url = item.url else { return }
                                presentedItem = PresentedItem(musicItem: item, url: url)
                            }
                    }
                }
            }
        }
    }

    private func centeredPlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 12) { content() }.padding(.vertical, 60)
            Spacer()
        }
    }

    // MARK: - Search

    private func performSearch() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            do {
                var request = MusicCatalogSearchRequest(term: query, types: [Album.self, Playlist.self])
                request.limit = 20
                let response = try await request.response()
                guard !Task.isCancelled else { return }

                var items: [UserMusicItem] = []
                items.append(contentsOf: response.albums.map { $0.toUserMusicItem() })
                items.append(contentsOf: response.playlists.map { $0.toUserMusicItem() })
                searchResults = items
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
            }
            isSearching = false
        }
    }
}

// MARK: - Music Item Card

struct MusicItemCard: View {
    let item: UserMusicItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkView
            VStack(alignment: .leading, spacing: 2) {
                Text(item.itemName ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.artistName ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var artworkView: some View {
        AsyncImage(url: item.artwork?.url(width: 480, height: 480)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay { Image(systemName: "music.note").font(.title2).foregroundStyle(.tertiary) }
            default:
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay { ProgressView() }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Player View

struct PlayerView: View {
    let item: PresentedItem

    @Environment(\.dismiss) private var dismiss

    // Artwork animation
    @State private var artworkLoaded = false

    // Playback
    @State private var hlsURL: URL?
    @State private var isLoadingAmbience = true
    @State private var tracks: MusicItemCollection<Track>?

    // Export
    @State private var exportVariants: [AmbienceExporter.Variant] = []
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    // Feedback
    @State private var exportErrorMessage: String?
    @State private var showSavedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                artworkCard
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 28)

                metadataSection
                    .padding(.horizontal, 20)

                if isExporting {
                    exportProgressBar
                        .padding(.top, 24)
                        .padding(.horizontal, 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if !exportVariants.isEmpty, !isExporting {
                    saveSection
                        .padding(.top, 24)
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                if let tracks, !tracks.isEmpty {
                    tracksSection(tracks)
                        .padding(.top, 28)
                }

                Spacer(minLength: 48)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isExporting)
        .animation(.easeInOut(duration: 0.35), value: exportVariants.isEmpty)
        .navigationTitle(item.musicItem?.itemName ?? "Ambience")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        #endif
        .overlay {
            if showSavedToast {
                savedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSavedToast)
        .alert("Export Failed", isPresented: .init(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadAmbience() }
                group.addTask { await loadTracks() }
            }
        }
    }

    // MARK: - Toast

    private var savedToast: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved to Photos")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Artwork Card

    private var artworkCard: some View {
        ZStack {
            artworkBase

            if let url = hlsURL {
                AmbienceArtworkPlayer(url: url)
                    #if os(macOS)
                    .ambienceArtworkContentMode(.resizeAspectFill)
                    #else
                    .ambienceArtworkContentMode(.scaleAspectFill)
                    #endif
                    .ambienceLooping(true)
                    .ambienceAutoPlay(true)
                    .transition(.opacity)
            }

            if isLoadingAmbience {
                Color.clear
                    .overlay(alignment: .bottomTrailing) {
                        ProgressView()
                            .tint(.white)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(12)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private var artworkBase: some View {
        if let artworkURL = item.musicItem?.artwork?.url(width: 600, height: 600) {
            AsyncImage(url: artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: artworkLoaded ? 0 : 20)
                        .scaleEffect(artworkLoaded ? 1.0 : 1.1)
                        .opacity(artworkLoaded ? 1.0 : 0)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.7)) {
                                artworkLoaded = true
                            }
                        }
                } else {
                    placeholderRect
                }
            }
        } else {
            placeholderRect
        }
    }

    private var placeholderRect: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 52))
                    .foregroundStyle(.quaternary)
            }
    }

    // MARK: - Save Section

    private var saveSection: some View {
        VStack(spacing: 12) {
            Menu {
                ForEach(exportVariants) { variant in
                    Button {
                        startExport(variant: variant)
                    } label: {
                        Label(variant.displayName, systemImage: variant.tier.systemImage)
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Label("Download artwork to Photos", systemImage: "arrow.down.to.line")
                        .font(.body.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Export Progress

    private var exportProgressBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Saving…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", exportProgress * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    exportTask?.cancel()
                    isExporting = false
                    exportProgress = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: max(0.01, exportProgress))
                .tint(.accentColor)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.musicItem?.itemName ?? "Ambience")
                .font(.title2.bold())

            if let artist = item.musicItem?.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Tracklist

    private func tracksSection(_ tracks: MusicItemCollection<Track>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)

                        Text(track.title)
                            .font(.callout)
                            .lineLimit(1)

                        Spacer()

                        if let duration = track.duration {
                            Text(formattedDuration(duration))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 9)

                    if index < tracks.count - 1 {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Export Logic

    private func startExport(variant: AmbienceExporter.Variant) {
        isExporting = true
        exportProgress = 0

        let stem = item.musicItem?.itemName?
            .replacingOccurrences(of: "/", with: "-")
            .prefix(60)
            .trimmingCharacters(in: .whitespaces) ?? "ambience"

        exportTask = Task {
            defer {
                isExporting = false
                exportProgress = 0
            }
            do {
                let mp4URL = try await AmbienceExporter.export(
                    variant: variant,
                    outputName: stem,
                    onProgress: { progress in exportProgress = progress }
                )
                try await saveToPhotos(mp4URL)
                try? FileManager.default.removeItem(at: mp4URL)

                showSavedToast = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showSavedToast = false
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    private func saveToPhotos(_ videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "AmbienceCompanion", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Photo Library access denied. Grant permission in Settings."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
    }

    // MARK: - Data Loading

    private func loadAmbience() async {
        do {
            let url = try await AmbienceService.resolveHLSURL(from: item.url)
            withAnimation(.easeIn(duration: 0.8)) {
                hlsURL = url
                isLoadingAmbience = false
            }
            exportVariants = (try? await AmbienceExporter.availableVariants(hlsURL: url)) ?? []
        } catch {
            isLoadingAmbience = false
        }
    }

    private func loadTracks() async {
        guard let musicItem = item.musicItem else { return }

        do {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: musicItem.id)
            request.properties = [.tracks]
            let response = try await request.response()
            if let albumTracks = response.items.first?.tracks, !albumTracks.isEmpty {
                tracks = albumTracks
                return
            }
        } catch {}

        do {
            var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: musicItem.id)
            request.properties = [.tracks]
            let response = try await request.response()
            if let playlistTracks = response.items.first?.tracks, !playlistTracks.isEmpty {
                tracks = playlistTracks
            }
        } catch {}
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func matchedTransitionSourceIfAvailable<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(deepLinkURL: .constant(nil))
}
