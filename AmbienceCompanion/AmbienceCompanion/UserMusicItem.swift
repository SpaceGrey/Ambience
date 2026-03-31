//
//  UserMusicItem.swift
//  animated artworks
//
//  Created by Shuhari on 2024/10/12.
//

import Foundation
import MusicKit

protocol UserMusicItemTransferable {
    func toUserMusicItem() -> UserMusicItem
}

struct UserMusicItem: MusicItem {
    var id: MusicItemID
    var artwork: Artwork?
    var itemName: String?
    var artistName: String?
    var url: URL?
    var editorialNotes: String?
}

extension UserMusicItem: Identifiable {}
extension UserMusicItem: Equatable {}
extension UserMusicItem: Hashable {}

extension Album: UserMusicItemTransferable {
    func toUserMusicItem() -> UserMusicItem {
        UserMusicItem(
            id: self.id,
            artwork: self.artwork,
            itemName: self.title,
            artistName: self.artistName,
            url: self.url,
            editorialNotes: self.editorialNotes?.standard ?? self.editorialNotes?.short
        )
    }
}

extension Playlist: UserMusicItemTransferable {
    func toUserMusicItem() -> UserMusicItem {
        UserMusicItem(
            id: self.id,
            artwork: self.artwork,
            itemName: self.name,
            artistName: self.curatorName,
            url: self.url,
            editorialNotes: nil
        )
    }
}
