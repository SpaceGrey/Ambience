//
//  AmbienceCompanionApp.swift
//  AmbienceCompanion
//
//  Created by Shuhari on 2024/10/12.
//

import SwiftUI

@main
struct AmbienceCompanionApp: App {
    @State private var deepLinkURL: URL?

    var body: some Scene {
        WindowGroup {
            ContentView(deepLinkURL: $deepLinkURL)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    guard url.scheme == "ambience",
                          url.host == "open",
                          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
                          let musicURL = URL(string: urlParam) else { return }
                    deepLinkURL = musicURL
                }
        }
        #if os(macOS)
        .defaultSize(width: 860, height: 640)
        #endif
    }
}
