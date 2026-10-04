//
//  NetEaseLyricsProvider.swift
//  boringNotch
//
//  NetEase Cloud Music (网易云音乐) lyrics lookup.
//
//  NetEase's macOS client exposes no AppleScript dictionary, and the app runs
//  inside the App Sandbox so its local lyric cache is unreachable either. The
//  only viable route is NetEase's public web endpoints, which need no account
//  but do require a Referer header.
//
//  Every failure path returns nil so the caller can fall back to another source.
//

import Foundation

// MARK: - Shared LRC parsing

/// A single timed lyric line, optionally carrying its translation.
struct LyricLine: Sendable, Equatable {
    let time: Double
    let text: String
    var translation: String?

    init(time: Double, text: String, translation: String? = nil) {
        self.time = time
        self.text = text
        self.translation = translation
    }
}

enum LRCParser {
    private static let timestampPattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#

    /// Parses `[mm:ss.xx]` / `[m:ss]` / `[mm:ss.xxx]` timestamps into sorted lines.
    static func parse(_ lrc: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return [] }

        var result: [LyricLine] = []
        for lineSub in lrc.split(separator: "\n") {
            let line = String(lineSub)
            let nsLine = line as NSString
            guard let match = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: nsLine.length))
            else { continue }

            let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
            let fractionRange = match.range(at: 3)
            var fraction = 0.0
            if fractionRange.location != NSNotFound {
                let raw = nsLine.substring(with: fractionRange)
                // "[00:01.5]" means 500ms, "[00:01.50]" means 500ms, "[00:01.500]" means 500ms.
                fraction = (Double(raw) ?? 0) / pow(10, Double(raw.count))
            }

            let text = nsLine
                .substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isMetadata(text) else { continue }

            result.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Folds a translation track onto the original lines by matching timestamps.
    /// NetEase emits both tracks with identical timestamps, so an exact match on
    /// the parsed time is reliable; a small tolerance absorbs rounding drift.
    static func merge(translation: [LyricLine], into lines: [LyricLine]) -> [LyricLine] {
        guard !lines.isEmpty, !translation.isEmpty else { return lines }

        var byTime: [Double: String] = [:]
        for entry in translation {
            byTime[(entry.time * 1000).rounded()] = entry.text
        }

        return lines.map { line in
            var copy = line
            if let hit = byTime[(line.time * 1000).rounded()] {
                // NetEase repeats the original text when it has no translation for a line.
                copy.translation = hit == line.text ? nil : hit
            }
            return copy
        }
    }

    /// Credit keys NetEase uses to open a track. They are only consulted when the
    /// line really reads `key : value`, so a lyric that happens to contain a colon
    /// is left alone.
    private static let creditKeys: Set<String> = [
        "作词", "作曲", "编曲", "制作人", "制作", "和声", "和声编写", "配唱", "监制",
        "吉他", "贝斯", "鼓", "键盘", "弦乐", "口琴", "录音", "录音师", "录音工程师",
        "混音", "混音师", "母带", "母带工程师", "出品", "出品人", "发行", "策划",
        "统筹", "企划", "总监制", "词", "曲", "op", "sp",
        "lyrics", "lyric", "composed", "composer", "arranged", "arranger",
        "produced", "producer", "mixed", "mastered", "written",
        "lyrics by", "composed by", "arranged by", "produced by", "mixed by",
        "mastered by", "written by", "music by",
    ]

    /// What NetEase puts in the `lrc` field of a release that has no lyrics at
    /// all. Left in, one of these would be the only thing on screen for the whole
    /// track.
    private static let placeholderLines: Set<String> = [
        "纯音乐，请欣赏", "纯音乐请欣赏", "纯音乐", "纯音乐，请您欣赏",
        "此歌曲为没有填词的纯音乐，请您欣赏", "该歌曲为纯音乐，请欣赏",
        "暂无歌词", "暂无歌词，请欣赏",
    ]

    /// Whether a timed line is credits or a no-lyrics placeholder rather than
    /// something that gets sung.
    ///
    /// NetEase stamps the credits of a track with real timestamps —
    /// `[00:00.00] 作词 : 米津玄師` — so without this they are handed back as if
    /// they were lyrics. That put six credit rows in 晴天's opening five seconds,
    /// and made マリーゴールド open with nothing but credits for 21 seconds.
    private static func isMetadata(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeholderLines.contains(line) { return true }

        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" })
        else { return false }
        let key = line[line.startIndex..<separator]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return !key.isEmpty && key.count <= 12 && creditKeys.contains(key)
    }
}

// MARK: - Provider

/// Looks up lyrics from NetEase Cloud Music.
///
/// This talks to undocumented NetEase endpoints, so it is deliberately
/// best-effort: any non-200 response, malformed payload, missing lyric or
/// network error resolves to `nil` and lets the caller fall back.
actor NetEaseLyricsProvider {
    static let shared = NetEaseLyricsProvider()

    /// Bundle identifier of the NetEase Cloud Music macOS client.
    static let bundleIdentifier = "com.netease.163music"

    /// How many ranked candidates a lookup will try before giving up. Normally
    /// only the first is needed; the rest exist so that a lyric-less take winning
    /// the duration ranking cannot sink the whole lookup.
    private static let candidateAttempts = 3

    private let searchEndpoint = "https://music.163.com/api/search/get/web"
    private let lyricEndpoint = "https://music.163.com/api/song/lyric"

    private var hits: [String: [LyricLine]] = [:]
    private var misses: Set<String> = []
    private let cacheLimit = 200

    // MARK: Outcomes

    /// What one attempt concluded.
    ///
    /// The three cases exist because only a real verdict may be cached. NetEase
    /// answers a burst with HTTP 200 and a body carrying a non-200 `code`
    /// (406 and 405 were both seen), and storing that refusal as "this track has
    /// no lyrics" would hide the track for the rest of the session.
    private enum LookupOutcome {
        case lyrics([LyricLine])
        case notFound
        case transient
    }

    private enum SearchOutcome {
        case ranked([Int])
        case notFound
        case transient
    }

    private enum LyricOutcome {
        case lyrics([LyricLine])
        case notFound
        case transient
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": "https://music.163.com/",
        ]
        return URLSession(configuration: config)
    }()

    // MARK: Public entry point

    /// Returns timed lyrics for a track, or `nil` when NetEase has nothing usable.
    ///
    /// - Parameters:
    ///   - title: Track title as reported by the now-playing source.
    ///   - artist: Track artist as reported by the now-playing source.
    ///   - duration: Track length in seconds; `0` disables duration matching.
    func lyrics(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        let key = cacheKey(title: cleanTitle, artist: artist, duration: duration)
        if let cached = hits[key] { return cached }
        if misses.contains(key) { return nil }

        switch await lookUp(title: cleanTitle, artist: artist, duration: duration) {
        case .lyrics(let lines):
            remember(hit: lines, for: key)
            return lines

        case .notFound:
            remember(miss: key)
            return nil

        case .transient:
            // Throttling clears within tens of seconds, so one delayed retry
            // rescues the common case without turning into a backoff loop.
            try? await Task.sleep(for: .seconds(3))
            switch await lookUp(title: cleanTitle, artist: artist, duration: duration) {
            case .lyrics(let lines):
                remember(hit: lines, for: key)
                return lines
            case .notFound:
                remember(miss: key)
                return nil
            case .transient:
                // Still throttled, so this is not a verdict on the track: leave
                // it uncached so a later attempt can still succeed, and let the
                // caller show its fallback in the meantime.
                return nil
            }
        }
    }

    // MARK: Lookup

    private func lookUp(title: String, artist: String, duration: Double) async -> LookupOutcome {
        let candidates: [Int]
        switch await searchCandidates(title: title, artist: artist, duration: duration) {
        case .transient:
            return .transient
        case .notFound:
            return .notFound
        case .ranked(let ids):
            candidates = ids
        }

        // Walk the ranked candidates rather than betting on the top one. The
        // closest duration is usually the studio release, but an instrumental or
        // karaoke take can win on duration alone and then turn out to carry no
        // lyrics at all — マリーゴールド's instrumental does exactly that, while
        // two complete releases sat right behind it in the same result set.
        var throttled = false
        for songID in candidates {
            switch await fetchLyrics(songID: songID) {
            case .lyrics(let lines):
                return .lyrics(lines)
            case .notFound:
                continue
            case .transient:
                throttled = true
                continue
            }
        }
        return throttled ? .transient : .notFound
    }

    // MARK: Search

    private struct SearchResult: Decodable {
        struct Payload: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String }
                let id: Int
                let name: String
                let duration: Double?
                let artists: [Artist]?
            }
            let songs: [Song]?
        }
        let result: Payload?
    }

    private func searchCandidates(
        title: String, artist: String, duration: Double
    ) async -> SearchOutcome {
        // Bracketed qualifiers skew NetEase's relevance ranking badly enough to
        // return unrelated tracks — searching "夜曲 (Live) 周杰伦" surfaces ten songs
        // that are not 夜曲 at all — so the query uses the plain title. Matching
        // below still compares the full titles.
        let stripped = removingBracketedSegments(from: title)
        let queryTitle = stripped.isEmpty ? title : stripped
        let query = artist.isEmpty ? queryTitle : "\(queryTitle) \(artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(searchEndpoint)?s=\(encoded)&type=1&limit=10")
        else { return .notFound }

        // A transport failure is not a verdict on the track either, so it is
        // reported as transient rather than cached away.
        guard let data = await get(url) else { return .transient }
        if isThrottled(data) { return .transient }

        guard let decoded = try? JSONDecoder().decode(SearchResult.self, from: data),
              let songs = decoded.result?.songs,
              !songs.isEmpty
        else { return .notFound }

        return .ranked(rank(songs, title: title, artist: artist, duration: duration))
    }

    /// Words NetEase uses to label a release that has no vocals to show lyrics
    /// for. Such a take shares the studio release's duration, so it ranks well
    /// while being guaranteed to come back empty.
    private static let instrumentalMarkers = [
        "instrumental", "off vocal", "offvocal", "off-vocal", "karaoke",
        "inst.", "(inst", "カラオケ", "オフボーカル", "伴奏", "纯音乐", "純音樂",
        "无人声", "無人声", "無人聲", "无人聲",
    ]

    private func isInstrumental(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return Self.instrumentalMarkers.contains { lowered.contains($0) }
    }

    /// Orders the search results from most to least likely to be the track that
    /// is playing.
    ///
    /// NetEase search ranks by its own relevance and returns unrelated tracks —
    /// searching "夜曲 周杰伦" turns up covers plus 刀马旦, a different song that
    /// happens to feature the same artist. So candidates are first restricted to
    /// those whose title matches what is playing; only then does an artist match
    /// win, and only then does the closest duration decide. The full ordering is
    /// returned rather than a single winner, so the caller can move on if the
    /// best candidate turns out to have nothing to show.
    private func rank(
        _ songs: [SearchResult.Payload.Song], title: String, artist: String,
        duration: Double
    ) -> [Int] {
        let normalizedTitle = normalizeTitle(title)
        let titleMatched = songs.filter { titleMatches($0.name, normalizedTitle) }
        guard !titleMatched.isEmpty else { return [] }

        let singable = titleMatched.filter { !isInstrumental($0.name) }
        var pool = singable.isEmpty ? titleMatched : singable

        let wanted = normalize(artist)
        if !wanted.isEmpty {
            let matched = pool.filter { song in
                (song.artists ?? []).contains { normalize($0.name) == wanted }
            }
            if !matched.isEmpty { pool = matched }
        }

        guard duration > 0 else { return Array(pool.map(\.id).prefix(Self.candidateAttempts)) }

        // NetEase reports durations in milliseconds. Candidates that report no
        // duration keep their relative order at the back.
        let byDistance = pool
            .compactMap { song -> (id: Int, delta: Double)? in
                guard let ms = song.duration, ms > 0 else { return nil }
                return (song.id, abs(ms / 1000 - duration))
            }
            .sorted { $0.delta < $1.delta }
            .map(\.id)

        let leftovers = pool.map(\.id).filter { !byDistance.contains($0) }
        return Array((byDistance + leftovers).prefix(Self.candidateAttempts))
    }

    // MARK: Lyrics

    private struct LyricResponse: Decodable {
        struct Track: Decodable { let lyric: String? }
        let lrc: Track?
        let tlyric: Track?
    }

    private func fetchLyrics(songID: Int) async -> LyricOutcome {
        guard let url = URL(string: "\(lyricEndpoint)?id=\(songID)&lv=-1&kv=-1&tv=-1"),
              let data = await get(url)
        else { return .transient }

        if isThrottled(data) { return .transient }

        guard let decoded = try? JSONDecoder().decode(LyricResponse.self, from: data),
              let raw = decoded.lrc?.lyric
        else { return .notFound }

        let lines = LRCParser.parse(raw)
        guard !lines.isEmpty else { return .notFound }

        guard let translationRaw = decoded.tlyric?.lyric, !translationRaw.isEmpty else {
            return .lyrics(lines)
        }
        return .lyrics(LRCParser.merge(translation: LRCParser.parse(translationRaw), into: lines))
    }

    // MARK: Networking

    /// NetEase answers a burst of lookups with HTTP 200 and a body of
    /// `{"msg":"操作频繁，请稍候再试","code":406}` — a success status carrying a
    /// refusal. The `code` is not stable (405 was seen too), so any non-200 value
    /// counts. How long it lasts scales with the burst: a short one cleared in
    /// about 20 seconds, while 30 rapid requests earned a block still in force
    /// ten minutes later. Read as an ordinary empty result it would be cached as
    /// "this track has no lyrics", which is how one transient block used to hide
    /// a track for the rest of the session.
    private struct ErrorEnvelope: Decodable { let code: Int? }

    private func isThrottled(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let code = envelope.code
        else { return false }
        return code != 200
    }

    private func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: Cache

    private func cacheKey(title: String, artist: String, duration: Double) -> String {
        "\(normalize(title))|\(normalize(artist))|\(Int(duration.rounded()))"
    }

    private func normalize(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Reduces a track title to comparable form by dropping bracketed
    /// qualifiers and punctuation, so "夜曲（Cover）", "夜曲 (钢琴版) [原唱: 周杰伦]"
    /// and "Shape of You (feat. X)" all compare equal to their plain titles.
    private func normalizeTitle(_ string: String) -> String {
        removingBracketedSegments(from: string)
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }

    /// Drops "(…)" / "[…]" / "（…）" qualifiers while keeping the remaining wording
    /// intact, so latin titles are still searchable as written.
    private func removingBracketedSegments(from string: String) -> String {
        let openers: Set<Character> = ["(", "（", "[", "【", "〔"]
        let closers: Set<Character> = [")", "）", "]", "】", "〕"]

        var result = ""
        var depth = 0
        for character in string {
            if openers.contains(character) {
                depth += 1
            } else if closers.contains(character) {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func titleMatches(_ candidate: String, _ normalizedTitle: String) -> Bool {
        let candidateTitle = normalizeTitle(candidate)
        guard !candidateTitle.isEmpty, !normalizedTitle.isEmpty else { return false }
        return candidateTitle == normalizedTitle
            || candidateTitle.hasPrefix(normalizedTitle)
            || normalizedTitle.hasPrefix(candidateTitle)
    }

    private func remember(hit lines: [LyricLine], for key: String) {
        if hits.count >= cacheLimit {
            hits.removeAll()
            misses.removeAll()
        }
        hits[key] = lines
    }

    private func remember(miss key: String) {
        if misses.count >= cacheLimit {
            hits.removeAll()
            misses.removeAll()
        }
        misses.insert(key)
    }
}
