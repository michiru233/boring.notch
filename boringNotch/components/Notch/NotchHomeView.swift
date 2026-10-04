//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            MusicControlsView().drawingGroup().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.lyricsDisplayMode) private var lyricsDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            // Lyrics take the right half of the player. The title/artist block
            // keeps the rest and shrinks gracefully, since it scrolls.
            //
            // The two-line layout has rows to spare and spends them on a wider
            // column instead, because a 21pt line needs the room to stay whole.
            let twoLine = lyricsDisplayMode == .twoLine
            let lyricsWidth = min(
                twoLine ? 380 : 340,
                max(190, geo.size.width * (twoLine ? 0.72 : 0.58)))
            let infoWidth = max(
                0, geo.size.width - (Defaults[.enableLyrics] ? lyricsWidth + 12 : 0))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 12) {
                    songInfo(width: infoWidth)
                        .frame(width: infoWidth, alignment: .leading)

                    if Defaults[.enableLyrics] {
                        LyricsPanel()
                            .frame(width: lyricsWidth, alignment: .leading)
                    }
                }
                musicSlider
            }
        }
        // The notch occupies the top ~35pt of the window; 4pt of clearance is
        // enough, and the 6pt the old 10pt inset wasted now goes to the lyrics.
        .padding(.top, 4)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 2)
            // The slider bar and its time labels need ~24pt; the rest was dead
            // space that the lyrics panel can use instead.
            .frame(height: 27)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

/// Synced lyrics for the right half of the player, in one of two layouts.
///
/// `twoLine` gives the panel over to two large rows — the line being sung, bright
/// white and semibold, above the one that follows it, dimmed — and replaces both
/// whole as the song moves on. Trading the extra rows for type size is the whole
/// point: at 21pt a line is legible at a glance, where the dense scrolling layout
/// had to make do with 12.5pt.
///
/// `scroll` is the denser marquee. Lines travel upward continuously rather than
/// stepping once per line, the sung line sits in the second row, its neighbours
/// fade with distance, and a translation appears in a strip pinned to the bottom
/// so it stays put while the lyrics above it scroll past.
///
/// The panel takes whatever height the player leaves over and works out how much
/// fits, because that budget is not knowable from here: the notch is 190pt tall,
/// the control row and progress bar are fixed, and what remains for lyrics lands
/// around 67pt.
///
/// This view is pure: it renders exactly the frame it is handed, with `lines`
/// already resolved to whichever language is being shown. `LyricsPanel` below is
/// the piece that reads the player and feeds it.
struct LyricsView: View {
    let lines: [LyricLine]
    let mode: LyricsDisplayMode
    let index: Int
    let progress: Double
    let placeholder: String?

    // MARK: Scrolling layout

    private static let rowHeight: CGFloat = 15
    /// Where the sung line's top edge sits: one row down, so exactly one line of
    /// history stays visible above it.
    private static let anchorTop: CGFloat = rowHeight
    /// Reserved at the bottom for the translation of the sung line — but only
    /// when the track has translations at all, since most Chinese tracks do not
    /// and the space is better spent on another lyric line.
    private static let translationSlot: CGFloat = 21

    private static let currentSize: CGFloat = 12.5
    private static let otherSize: CGFloat = 11
    private static let translationSize: CGFloat = 9.5

    // MARK: Two-line layout

    /// The sung line carries the panel; the next one is a dimmed preview.
    private static let sungSize: CGFloat = 21
    private static let nextSize: CGFloat = 14
    /// How far the sung line may shrink before it is allowed to truncate. Short
    /// lines keep the full 21pt; a long Japanese line gives ground down to 15pt
    /// rather than losing its ending.
    private static let sungShrink: CGFloat = 15.0 / 21.0
    private static let nextShrink: CGFloat = 0.78
    /// The replacement is a cross-fade: a slide would read as the scrolling
    /// layout this mode exists to replace.
    private static let jumpDuration: Double = 0.25

    var body: some View {
        GeometryReader { geo in
            Group {
                if let placeholder {
                    placeholderView(placeholder)
                } else if mode == .twoLine {
                    twoLineLines
                } else {
                    scrollingLines(height: geo.size.height)
                }
            }
        }
    }

    private func placeholderView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.otherSize))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Two-line layout

    private var twoLineLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sungText.isEmpty ? " " : sungText)
                .font(.system(size: Self.sungSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(Self.sungShrink)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(nextText.isEmpty ? " " : nextText)
                .font(.system(size: Self.nextSize))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(Self.nextShrink)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Centred rather than top-aligned: the scrolling layout puts its sung line
        // 15pt down, and a centred block of two rows starts at almost exactly that
        // height, so switching layouts does not shift the text.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: Self.jumpDuration), value: index)
    }

    private var sungText: String {
        lines.indices.contains(index) ? lines[index].text : ""
    }

    private var nextText: String {
        lines.indices.contains(index + 1) ? lines[index + 1].text : ""
    }

    // MARK: Scrolling layout

    private func scrollingLines(height: CGFloat) -> some View {
        let reserved = Self.hasTranslation(lines) ? Self.translationSlot : 0
        let rows = Self.rowCount(for: height - reserved)
        let lyricsHeight = CGFloat(rows) * Self.rowHeight

        return VStack(alignment: .leading, spacing: 0) {
            scrollingRows(rows: rows)
                .frame(height: lyricsHeight, alignment: .top)
                // Lines enter and leave through a soft fade rather than a hard
                // cut, which is what a half-scrolled line needs to not look like
                // a rendering glitch.
                .mask(Self.edgeFade)
            if reserved > 0 {
                translationLine
                    .frame(height: max(0, height - lyricsHeight), alignment: .top)
            }
        }
    }

    /// How many lyric lines fit in whatever height the player leaves over. The
    /// count is derived rather than fixed — at least two rows, so the scroll
    /// always has somewhere to go.
    private static func rowCount(for height: CGFloat) -> Int {
        max(2, Int((height / rowHeight).rounded(.down)))
    }

    private static var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }

    private static func hasTranslation(_ lines: [LyricLine]) -> Bool {
        lines.contains { !($0.translation ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func scrollingRows(rows: Int) -> some View {
        let first = index - 1
        // Over one line's duration the stack rises by exactly one row, which
        // lands the next line precisely where the sung one started.
        let offset =
            Self.anchorTop - CGFloat(index - first) * Self.rowHeight
            - progress * Self.rowHeight

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<(rows + 2), id: \.self) { slot in
                row(at: first + slot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: offset)
    }

    private func row(at line: Int) -> some View {
        // Out-of-range slots still occupy their height, otherwise the rows below
        // them would jump as the window reaches the ends of the song.
        let text = lines.indices.contains(line) ? lines[line].text : ""
        let distance = abs(line - index)

        return Text(text.isEmpty ? " " : text)
            .font(
                .system(
                    size: distance == 0 ? Self.currentSize : Self.otherSize,
                    weight: distance == 0 ? .semibold : .regular)
            )
            .foregroundStyle(.white.opacity(Self.opacity(at: distance)))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
    }

    /// The sung line stays fully bright; everything else fades with distance.
    private static func opacity(at distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.5
        case 2: return 0.32
        default: return 0.2
        }
    }

    private var translationLine: some View {
        let translation =
            lines.indices.contains(index)
            ? lines[index].translation?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let text = (translation?.isEmpty ?? true) ? nil : translation

        return Text(text ?? " ")
            .font(.system(size: Self.translationSize))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Feeds `LyricsView` from the player. While the position is interpolated from
/// the last now-playing update the redraw is what keeps the scroll smooth.
struct LyricsPanel: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.lyricsDisplayMode) private var displayMode
    @Default(.lyricsLanguage) private var language

    var body: some View {
        TimelineView(.animation(minimumInterval: redrawInterval)) { timeline in
            let frame = musicManager.lyricFrame(at: timeline.date)

            LyricsView(
                lines: musicManager.displayLyrics(mode: displayMode, language: language),
                mode: displayMode,
                index: frame?.index ?? 0,
                progress: frame?.progress ?? 0,
                placeholder: frame == nil ? placeholderText : nil
            )
        }
        // Clicking the lyrics steps through Original / Translation / Automatic.
        // Which text to read is a per-track call people flip often — an
        // instrumental passage may want the original, a verse they cannot follow
        // the translation — so it lives on the panel itself rather than only in
        // Settings. The two-line layout redraws on line changes alone, so it
        // needs a far lazier clock than the scrolling one.
        .contentShape(Rectangle())
        .onTapGesture { language = language.next }
        .help("Lyrics language: \(language.rawValue) — click to change")
    }

    private var redrawInterval: Double {
        guard musicManager.isPlaying else { return 1 }
        return displayMode == .twoLine ? 0.2 : 0.05
    }

    private var placeholderText: String {
        if musicManager.isFetchingLyrics { return "Loading lyrics…" }
        let lyrics = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return lyrics.isEmpty ? "No lyrics found" : lyrics
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

            if Defaults[.showCalendar] {
                CalendarView()
                    .frame(width: shouldShowCamera ? 170 : 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
