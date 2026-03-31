# Ambience

Ambience is a Swift package for Apple Music animated artwork (ambient video).

## Features
- Fetch animated artwork from Apple Music links.
- Play artwork in SwiftUI, UIKit, and AppKit.
- Cache assets for smoother playback.
- Companion app for browsing, previewing, and exporting ambient artwork.

## Requirements
- iOS 15+
- macOS 14+
- visionOS 1+
- tvOS 16+
- watchOS 9+
- Swift 5.9+

## Installation (SPM)

```swift
dependencies: [
    .package(url: "https://github.com/zhangqifan/Ambience.git", .upToNextMajor(from: "1.2.0"))
]
```

## CLI Tool

A command-line tool for downloading Apple Music ambient videos as MP4 files. No Xcode or Swift knowledge required.

### Build

```bash
swift build -c release
cp .build/release/ambience-cli /usr/local/bin/
```

### Usage

**One-liner** — paste a link, get the best quality MP4 on your Desktop:

```bash
ambience-cli "https://music.apple.com/us/album/whatevers-clever/1845189970"
# => ~/Desktop/whatevers_clever.mp4
```

**Interactive mode** — just run without arguments and follow the prompts:

```bash
ambience-cli
```

```
  Ambience — Apple Music Ambient Video Exporter

  Paste an Apple Music link: https://music.apple.com/...
  ✓ Stream resolved.
  ✓ Found 4 quality tier(s).

  Available qualities:
    [1] Original   2160x2160   20.5 Mbps (default)
    [2] High       1080x1080   7.2 Mbps
    [3] Standard   720x720     3.1 Mbps
    [4] Low        360x360     255 kbps

  Choose quality [1]:
  Save to [~/Desktop/whatevers_clever.mp4]:

  ✓ Saved: ~/Desktop/whatevers_clever.mp4 (737 MB)
```

**With options:**

```bash
# Specify quality and output path
ambience-cli "https://music.apple.com/..." -q high -o ~/Movies/ambient.mp4

# Quality choices: original (default), high, standard, low
```

> Storefront redirects are handled automatically — a US link works from any region.

---

## Swift Package Usage

### 1) Fetch an ambience asset

```swift
import Ambience

let musicItemURL = URL(string: "https://music.apple.com/us/album/...")!
let localAssetURL = try await AmbienceService.fetchAmbienceAsset(from: musicItemURL)
```

### 2) Show artwork in SwiftUI

```swift
import SwiftUI
import Ambience

struct DemoView: View {
    let ambienceURL: URL

    var body: some View {
        AmbienceArtworkPlayer(url: ambienceURL)
            .ambienceAutoPlay(true)
            .ambienceLooping(true)
            .aspectRatio(1, contentMode: .fit)
    }
}
```

### 3) Export to MP4

```swift
import Ambience

let musicItemURL = URL(string: "https://music.apple.com/us/album/...")!
let hlsURL = try await AmbienceService.resolveHLSURL(from: musicItemURL)
let variants = try await AmbienceExporter.availableVariants(hlsURL: hlsURL)
let outputURL = try await AmbienceExporter.export(variant: variants.first!)
print(outputURL)
```

## Companion App

A redesigned demo app for browsing, previewing, and saving ambient artwork. Requires **iOS 26+**.

<p align="center">
  <img src="docs/images/companion-redesign.png" width="400" height="400" alt="Ambience Companion" />
</p>

- MusicKit catalog search and personal recommendations.
- Ambient video player with artwork reveal animation.
- Multi-quality export (Low / Standard / High / Original) saved directly to Photos.
- Share Extension for opening Apple Music links in the app.

## Companion App Setup
1. Open `AmbienceCompanion/AmbienceCompanion.xcodeproj` in Xcode.
2. Set your own bundle identifier and signing team.
3. In the **Info** tab of the AmbienceCompanion target, add a **URL Type** with scheme `ambience` (required for the share extension to redirect into the app).
4. Enable **MusicKit** capability in the Apple Developer portal.
5. Build and run on iOS 26+.

## License
MIT. See [LICENSE](LICENSE).
