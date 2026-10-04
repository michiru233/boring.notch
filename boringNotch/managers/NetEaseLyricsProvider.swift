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
            guard !text.isEmpty else { continue }

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

    /// Playback duration tolerance used when picking a search candidate. Keeps
    /// covers, live takes and remixes from winning over the studio version.
    private static let durationTolerance: Double = 3

    private let searchEndpoint = "https://music.163.com/api/search/get/web"
    private let lyricEndpoint = "https://music.163.com/api/song/lyric"

    private var hits: [String: [LyricLine]] = [:]
    private var misses: Set<String> = []
    private let cacheLimit = 200

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

        guard let songID = await searchSongID(title: cleanTitle, artist: artist, duration: duration)
        else {
            remember(miss: key)
            return nil
        }

        guard let lines = await fetchLyrics(songID: songID) else {
            remember(miss: key)
            return nil
        }

        remember(hit: lines, for: key)
        return lines
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

    private func searchSongID(title: String, artist: String, duration: Double) async -> Int? {
        // Bracketed qualifiers skew NetEase's relevance ranking badly enough to
        // return unrelated tracks — searching "夜曲 (Live) 周杰伦" surfaces ten songs
        // that are not 夜曲 at all — so the query uses the plain title. Matching
        // below still compares the full titles.
        let stripped = removingBracketedSegments(from: title)
        let queryTitle = stripped.isEmpty ? title : stripped
        let query = artist.isEmpty ? queryTitle : "\(queryTitle) \(artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(searchEndpoint)?s=\(encoded)&type=1&limit=10")
        else { return nil }

        guard let data = await get(url),
              let decoded = try? JSONDecoder().decode(SearchResult.self, from: data),
              let songs = decoded.result?.songs,
              !songs.isEmpty
        else { return nil }

        return pick(from: songs, title: title, artist: artist, duration: duration)
    }

    /// Chooses among search candidates.
    ///
    /// NetEase search ranks by its own relevance and returns unrelated tracks —
    /// searching "夜曲 周杰伦" turns up covers plus 刀马旦, a different song that
    /// happens to feature the same artist. So candidates are first restricted to
    /// those whose title matches what is playing; only then does an artist match
    /// win, and only then does the closest duration decide. Returning nil (and
    /// letting the caller fall back to another source) beats showing the lyrics
    /// of a different song.
    private func pick(
        from songs: [SearchResult.Payload.Song], title: String, artist: String,
        duration: Double
    ) -> Int? {
        let normalizedTitle = normalizeTitle(title)
        let titleMatched = songs.filter { titleMatches($0.name, normalizedTitle) }
        guard !titleMatched.isEmpty else { return nil }

        var pool = titleMatched
        let wanted = normalize(artist)
        if !wanted.isEmpty {
            let matched = titleMatched.filter { song in
                (song.artists ?? []).contains { normalize($0.name) == wanted }
            }
            if !matched.isEmpty { pool = matched }
        }

        guard duration > 0 else { return pool.first?.id }

        // NetEase reports durations in milliseconds.
        let ranked = pool.compactMap { song -> (id: Int, delta: Double)? in
            guard let ms = song.duration, ms > 0 else { return nil }
            return (song.id, abs(ms / 1000 - duration))
        }
        guard let best = ranked.min(by: { $0.delta < $1.delta }) else { return pool.first?.id }

        return best.id
    }

    // MARK: Lyrics

    private struct LyricResponse: Decodable {
        struct Track: Decodable { let lyric: String? }
        let lrc: Track?
        let tlyric: Track?
    }

    private func fetchLyrics(songID: Int) async -> [LyricLine]? {
        guard let url = URL(string: "\(lyricEndpoint)?id=\(songID)&lv=-1&kv=-1&tv=-1"),
              let data = await get(url),
              let decoded = try? JSONDecoder().decode(LyricResponse.self, from: data),
              let raw = decoded.lrc?.lyric
        else { return nil }

        let lines = LRCParser.parse(raw)
        guard !lines.isEmpty else { return nil }

        guard let translationRaw = decoded.tlyric?.lyric, !translationRaw.isEmpty else {
            return lines
        }
        return LRCParser.merge(translation: LRCParser.parse(translationRaw), into: lines)
    }

    // MARK: Networking

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
