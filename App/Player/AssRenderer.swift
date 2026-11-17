import AetherHost
import CoreGraphics
import Foundation
import SwiftLibass
import UIKit

/**
 * libass drawing an ASS/SSA track, as mpv and the Android app's ExoPlayer path draw them: the file's
 * styles, positioning, animation, karaoke, drawings and fonts. Text tracks stay the overlay's own drawing.
 *
 * The engine hands over the track's header (`[Script Info]` and
 * `[V4+ Styles]`) and its events as Matroska event lines
 * (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`), which is
 * what libass's `ass_process_chunk` reads, so events go in as they arrive.
 *
 * Every libass call runs on one serial queue; the rest is the main thread's.
 * Renders are coalesced: while one runs, only the latest request waits.
 */
final class AssRenderer: @unchecked Sendable {
    /// Where libass draws, in pixels: the screen, with the picture inside it.
    struct Layout: Equatable {
        var frameWidth: Int32
        var frameHeight: Int32
        /// The picture's edges from the frame's: negative when the picture runs off it (crop).
        var top: Int32
        var bottom: Int32
        var left: Int32
        var right: Int32
        /// Cues not placed by the script may use the whole frame, so they stay on screen when cropped.
        var useMargins: Bool
        /// The page's subtitle scale, as mpv's `sub-scale` applies it to ASS, on dialogue only.
        var fontScale: Double
        /// The page's subtitle height, as mpv gives libass its `sub-pos` (`100 - sub-pos`): percent of the
        /// picture that dialogue without a position of its own moves up from the bottom, 0 leaving it.
        var linePosition: Double

        /// The video's own size, as it's stored (anamorphic too), as mpv and the Android app give libass its
        /// storage size: `\blur`, and borders and shadows with `ScaledBorderAndShadow: no`, scale from it.
        /// 0 when not known yet: the picture's size on screen stands in.
        var videoWidth: Int32
        var videoHeight: Int32

        /// The page's look, when it forces its style on the file's (mpv's `sub-ass-override=force`); nil keeps the file's.
        var forced: ForcedStyle?

        var pictureWidth: Int32 { frameWidth - left - right }
        var pictureHeight: Int32 { frameHeight - top - bottom }
    }

    /**
     * The page's look as libass's override style, as the Android app's ExoPlayer path and mpv force it:
     * font, sizes, colours and border, on dialogue only. libass leaves an event placed by the script
     * (`\pos`, `\move` and the like) its own style, so signs keep theirs where the script put them.
     */
    struct ForcedStyle: Equatable {
        /// A family libass finds: the device's through CoreText, or one of the app's (`SubtitleFonts.files`).
        var fontName: String
        var bold: Bool
        /// ASS's colours: `RRGGBBAA`, the alpha byte as transparency.
        var color: UInt32
        var outlineColor: UInt32
        /// The box's colour with a box; the shadow's otherwise, as ASS draws the shadow in it.
        var backColor: UInt32
        var boxed: Bool
        /// In units of a 720-line screen, the page's and the text drawing's own.
        var fontSize: Double
        var outline: Double
        var shadow: Double
        var margin: Double
    }

    enum Output {
        /// What's drawn still stands.
        case unchanged
        /// Nothing to draw now.
        case empty
        /// One picture of everything showing, and where it goes in the frame, in pixels.
        case frame(CGImage, CGRect)
    }

    private let queue = DispatchQueue(label: "io.github.aiostreams.ass", qos: .userInteractive)

    // Queue only, after `init`.
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var applied: Layout?
    /// The file's attached fonts, and the names each answers to (nil where it can't be read, given always).
    private var attached: [(name: String, data: Data, names: Set<String>?)] = []
    /// Which of `attached` libass has.
    private var given = Set<Int>()
    /// The font names the track's styles and its lines' `\fn` ask for.
    private var wanted = Set<String>()
    /// libass's bitmap cache in MB, 0 for its own limit.
    private var cacheMB: Int32 = 0

    // Main thread only.
    /// The file's fonts, by name and size, so the next episode's same set isn't read again.
    private var fontKeys: [String] = []
    private var generation = 0
    /// Events given to the track, so a re-published cue list adds only what's new.
    private var seen = Set<String>()
    private var busy = false
    private var pending: Job?
    private var memoryWatch: NSObjectProtocol?

    private struct Job {
        let milliseconds: Int64
        let layout: Layout
        let generation: Int
        let completion: (Output) -> Void
    }

    init() {
        // As the Android app: libass's cache kept small on a device with less than 4 GB of memory, and
        // smaller still once the system says memory is short.
        cacheMB = ProcessInfo.processInfo.physicalMemory < Self.smallDeviceBytes ? Self.smallCacheMB : 0
        start()
        memoryWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.cacheMB != Self.shortCacheMB else { return }
                self.cacheMB = Self.shortCacheMB
                if let renderer = self.renderer { ass_set_cache_limits(renderer, 0, self.cacheMB) }
                EngineLogBook.note("[subtitles] memory short: libass keeps \(Self.shortCacheMB) MB of drawn subtitles")
            }
        }
    }

    deinit {
        if let memoryWatch { NotificationCenter.default.removeObserver(memoryWatch) }
        stop()
    }

    /// The Android app's CacheBudget: "under this, a 3 GB device; 4 GB ones report more".
    private static let smallDeviceBytes: UInt64 = 3_400_000_000
    private static let smallCacheMB: Int32 = 32
    private static let shortCacheMB: Int32 = 8

    /// A new library and renderer, with the app's own faces. Queue only, or `init`.
    private func start() {
        library = ass_library_init()
        applied = nil
        given.removeAll()
        guard let library else {
            EngineLogBook.note("[subtitles] libass did not start")
            return
        }
        // libass's errors in the log, as the Android app keeps them (levels 0 and 1); its notes, as each
        // font it picks, would fill it.
        ass_set_message_cb(library, { level, format, arguments, _ in
            guard level <= 1, let format, let arguments else { return }
            var text = [CChar](repeating: 0, count: 512)
            let message = text.withUnsafeMutableBufferPointer { buffer -> String in
                _ = vsnprintf(buffer.baseAddress, buffer.count, format, arguments)
                return String(cString: buffer.baseAddress!)
            }
            EngineLogBook.note("[subtitles] libass: \(message)")
        }, nil)
        // Fonts a script carries in its own [Fonts] section.
        ass_set_extract_fonts(library, 1)
        // The app's own faces, which the page's style can force (Casual, Cursive), as tvOS has none of its own.
        for font in SubtitleFonts.fileData { addFont(font.name, font.data) }
        startRenderer()
    }

    /// The renderer, again after fonts are added: libass keeps the font it picked for each name. Queue only.
    private func startRenderer() {
        if let renderer { ass_renderer_done(renderer) }
        renderer = library.flatMap { ass_renderer_init($0) }
        applied = nil
        guard let renderer else { return }
        if cacheMB > 0 { ass_set_cache_limits(renderer, 0, cacheMB) }
        // tvOS's own fonts through CoreText, with Helvetica Neue in place of a family none has,
        // and CoreText's fallback for characters the chosen font lacks.
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 0)
        // The font scale only sizes what looks like dialogue, so signs and other typesetting keep
        // the size and place the script gave them.
        ass_set_selective_style_override_enabled(renderer, Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue))
    }

    /// libass copies the bytes. Queue only.
    private func addFont(_ name: String, _ data: Data) {
        guard let library else { return }
        var bytes = [CChar](repeating: 0, count: data.count)
        bytes.withUnsafeMutableBytes { target in _ = data.copyBytes(to: target) }
        name.withCString { name in
            let name = strdup(name)
            defer { free(name) }
            bytes.withUnsafeMutableBufferPointer { buffer in
                ass_add_font(library, name, buffer.baseAddress, Int32(buffer.count))
            }
        }
    }

    /// Frees the track, renderer and library, in that order: libass lets go of fonts only with all three gone.
    private func stop() {
        if let track { ass_free_track(track) }
        if let renderer { ass_renderer_done(renderer) }
        if let library { ass_library_done(library) }
        track = nil
        renderer = nil
        library = nil
    }

    // MARK: The fonts

    /**
     * The playing file's attached fonts. A different set from the last file's starts libass over, dropping
     * the track: returns true then, and the caller loads the track again. The same set keeps all.
     *
     * As the Android app's AssFonts, libass is given only the fonts the shown track asks for, by its styles'
     * names and its lines' `\fn`, as it asks: an anime release can carry dozens, and most tracks use a few.
     */
    @discardableResult
    func setFonts(_ fonts: [FontAttachment]) -> Bool {
        let keys = fonts.map { "\($0.filename)|\($0.data.count)" }
        guard keys != fontKeys else { return false }
        fontKeys = keys
        generation += 1
        seen.removeAll()
        let files = fonts.map { (name: $0.filename, data: $0.data) }
        queue.async { [self] in
            stop()
            start()
            attached = files.map { (name: $0.name, data: $0.data, names: Self.fontNames($0.data)) }
            wanted.removeAll()
            let total = files.reduce(0) { $0 + $1.data.count }
            EngineLogBook.note("[subtitles] \(files.count) attached fonts (\(total / 1024) KB), given to libass as tracks ask for them")
        }
        return true
    }

    /// Hands libass the attached fonts the track asks for that it hasn't had. Queue only.
    private func giveFonts() {
        let giving = attached.indices.filter { index in
            !given.contains(index) && (attached[index].names.map { !$0.isDisjoint(with: wanted) } ?? true)
        }
        guard !giving.isEmpty else { return }
        for index in giving {
            addFont(attached[index].name, attached[index].data)
            given.insert(index)
        }
        startRenderer()
        let bytes = giving.reduce(0) { $0 + attached[$1].data.count }
        EngineLogBook.note("[subtitles] gave libass \(giving.count) more of \(attached.count) attached fonts (\(bytes / 1024) KB)")
    }

    // MARK: The track

    /// Starts a new track from its header, dropping the old one's events.
    func load(header: String) {
        generation += 1
        seen.removeAll()
        // MKV CodecPrivate is often NUL-terminated, and libass reads it as a C string.
        let cleaned = header.replacingOccurrences(of: "\0", with: "")
        let bytes = Array(cleaned.utf8)
        let named = Self.styleFonts(cleaned)
        queue.async { [self] in
            if let track { ass_free_track(track) }
            track = library.flatMap { ass_new_track($0) }
            guard let track else { return }
            bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ass_process_codec_private(track, $0, Int32(buffer.count))
                }
            }
            // Many files number every event 0, so ReadOrder can't tell repeats apart; `seen` does.
            ass_set_check_readorder(track, 0)
            wanted = named
            giveFonts()
        }
    }

    func unload() {
        generation += 1
        seen.removeAll()
        queue.async { [self] in
            if let track { ass_free_track(track) }
            track = nil
        }
    }

    /// Gives the track the cues' events it hasn't had. A cue may hold several, one per line.
    func add(_ cues: [SubtitleCueEvent]) {
        var fresh: [(bytes: [UInt8], start: Int64, duration: Int64)] = []
        for cue in cues {
            for line in cue.text.split(separator: "\n", omittingEmptySubsequences: true) {
                let key = "\(cue.start)|\(cue.end)|\(line)"
                guard seen.insert(key).inserted else { continue }
                let start = Int64((cue.start * 1000).rounded())
                let duration = max(0, Int64((cue.end * 1000).rounded()) - start)
                fresh.append((Array(line.utf8), start, duration))
            }
        }
        guard !fresh.isEmpty else { return }
        queue.async { [self] in
            guard let track else { return }
            var asked = false
            for event in fresh {
                event.bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                        ass_process_chunk(track, $0, Int32(buffer.count), event.start, event.duration)
                    }
                }
                for name in Self.overrideFonts(event.bytes) where wanted.insert(name).inserted { asked = true }
            }
            if asked { giveFonts() }
        }
    }

    // MARK: Font names

    /// A name as libass compares it: a vertical font's `@` dropped, case ignored (the Android app's fontKey).
    static func fontKey(_ name: Substring) -> String {
        var key = name.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("@") { key.removeFirst() }
        return key.lowercased()
    }

    /// The families a header's styles name (`[V4+ Styles]`, by its `Format:` line's Fontname column).
    static func styleFonts(_ header: String) -> Set<String> {
        var names = Set<String>()
        var styles = false
        var column = 1
        for raw in header.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                styles = line.range(of: "styles", options: .caseInsensitive) != nil
            } else if !styles {
                continue
            } else if line.hasPrefix("Format:") {
                let fields = line.dropFirst("Format:".count).split(separator: ",", omittingEmptySubsequences: false)
                column = fields.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "fontname" } ?? 0
            } else if line.hasPrefix("Style:") {
                let fields = line.dropFirst("Style:".count).split(separator: ",", omittingEmptySubsequences: false)
                if column < fields.count {
                    let key = fontKey(fields[column])
                    if !key.isEmpty { names.insert(key) }
                }
            }
        }
        return names
    }

    /// The families a line's `\fn` tags name.
    static func overrideFonts(_ line: [UInt8]) -> [String] {
        var names: [String] = []
        let backslash = UInt8(ascii: "\\"), f = UInt8(ascii: "f"), n = UInt8(ascii: "n"), close = UInt8(ascii: "}")
        var i = 0
        while i + 3 <= line.count {
            guard line[i] == backslash, line[i + 1] == f, line[i + 2] == n else {
                i += 1
                continue
            }
            var end = i + 3
            while end < line.count, line[end] != backslash, line[end] != close { end += 1 }
            if let text = String(bytes: line[(i + 3)..<end], encoding: .utf8) {
                let key = fontKey(Substring(text))
                if !key.isEmpty { names.append(key) }
            }
            i = end
        }
        return names
    }

    /**
     * The names libass matches a script's font against: each face's family, full, PostScript and
     * typographic family names, lowercased; nil where the font can't be read (the Android app's FontNames).
     */
    static func fontNames(_ data: Data) -> Set<String>? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int? { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func u32(_ at: Int) -> Int? {
            guard let high = u16(at), let low = u16(at + 2) else { return nil }
            return high << 16 | low
        }
        let ttc = 0x7474_6366, nameTag = 0x6E61_6D65
        var faces = [0]
        if u32(0) == ttc, let count = u32(8) { faces = (0..<min(count, 64)).compactMap { u32(12 + $0 * 4) } }
        var names = Set<String>()
        for face in faces {
            guard let tables = u16(face + 4) else { continue }
            guard let record = (0..<tables).map({ face + 12 + $0 * 16 }).first(where: { u32($0) == nameTag }),
                  let table = u32(record + 8), let count = u16(table + 2), let offset = u16(table + 4)
            else { continue }
            let strings = table + offset
            for i in 0..<count {
                let at = table + 6 + i * 12
                guard let platform = u16(at), let id = u16(at + 6), [1, 4, 6, 16].contains(id),
                      let length = u16(at + 8), let start = u16(at + 10) else { continue }
                let from = strings + start
                guard from >= 0, from + length <= bytes.count else { continue }
                let slice = Data(bytes[from..<(from + length)])
                let text: String?
                switch platform {
                case 0, 3: text = String(data: slice, encoding: .utf16BigEndian)
                case 1: text = String(data: slice, encoding: .isoLatin1)
                default: text = nil
                }
                if let text {
                    let key = fontKey(Substring(text))
                    if !key.isEmpty { names.insert(key) }
                }
            }
        }
        return names.isEmpty ? nil : names
    }

    // MARK: Drawing

    /// Draws the track at `milliseconds`; `completion` gets the result on the main thread,
    /// unless the track has been replaced in the meantime.
    func render(at milliseconds: Int64, layout: Layout, completion: @escaping (Output) -> Void) {
        pending = Job(milliseconds: milliseconds, layout: layout, generation: generation, completion: completion)
        if !busy { runPending() }
    }

    private func runPending() {
        guard let job = pending else {
            busy = false
            return
        }
        pending = nil
        busy = true
        queue.async { [self] in
            let output = draw(at: job.milliseconds, layout: job.layout)
            DispatchQueue.main.async { [self] in
                if job.generation == generation { job.completion(output) }
                runPending()
            }
        }
    }

    /// Queue only.
    private func draw(at milliseconds: Int64, layout: Layout) -> Output {
        guard let renderer, let track else { return .empty }
        guard layout.frameWidth > 0, layout.frameHeight > 0,
              layout.pictureWidth > 0, layout.pictureHeight > 0 else { return .empty }
        if applied != layout {
            applied = layout
            ass_set_frame_size(renderer, layout.frameWidth, layout.frameHeight)
            // The video's own size; libass works the pixel aspect out from it and the picture's place.
            let stored = layout.videoWidth > 0 && layout.videoHeight > 0
            ass_set_storage_size(renderer, stored ? layout.videoWidth : layout.pictureWidth,
                                 stored ? layout.videoHeight : layout.pictureHeight)
            ass_set_margins(renderer, layout.top, layout.bottom, layout.left, layout.right)
            ass_set_use_margins(renderer, layout.useMargins ? 1 : 0)
            ass_set_font_scale(renderer, layout.fontScale)
            ass_set_line_position(renderer, layout.linePosition)
            override(layout.forced, renderer: renderer)
        }
        var changed: Int32 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        let images = ass_render_frame(renderer, track, milliseconds, &changed)
        if changed == 0 { return .unchanged }
        let rendered = DispatchTime.now().uptimeNanoseconds
        let composed = Self.compose(images)
        noteTiming(render: rendered - started, compose: DispatchTime.now().uptimeNanoseconds - rendered,
                   pixels: composed.map { Int($0.rect.width * $0.rect.height) } ?? 0)
        guard let composed else { return .empty }
        return .frame(composed.image, composed.rect)
    }

    /// Queue only. The font scale always sizes dialogue alone; forced, the page's look goes on it too.
    private func override(_ forced: ForcedStyle?, renderer: OpaquePointer) {
        var bits = ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue
        if let forced {
            bits |= ASS_OVERRIDE_BIT_FONT_NAME.rawValue | ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS.rawValue
                | ASS_OVERRIDE_BIT_COLORS.rawValue | ASS_OVERRIDE_BIT_BORDER.rawValue
            // The Android app also forces the blur: ASS_OVERRIDE_BIT_BLUR, 1 << 11, from libass 0.17.4. The
            // swift-libass package's 0.17.3 doesn't name it and ignores the bit; a newer one takes it.
            bits |= 1 << 11
            // libass reads the override style as set for a 288-line script, the page's sizes being 720 lines'.
            let units = 288.0 / 720.0
            var style = ASS_Style()
            style.FontSize = forced.fontSize * units
            style.PrimaryColour = forced.color
            style.SecondaryColour = forced.color
            style.OutlineColour = forced.outlineColor
            style.BackColour = forced.backColor
            style.Bold = forced.bold ? 1 : 0
            style.ScaleX = 1
            style.ScaleY = 1
            // mpv's outline-and-shadow and background box.
            style.BorderStyle = forced.boxed ? 4 : 1
            style.Outline = forced.outline * units
            style.Shadow = forced.shadow * units
            style.Alignment = 2
            let margin = Int32((forced.margin * units).rounded())
            style.MarginL = margin
            style.MarginR = margin
            style.MarginV = margin
            // libass keeps its own copy of the name.
            forced.fontName.withCString { name in
                style.FontName = UnsafeMutablePointer(mutating: name)
                ass_set_selective_style_override(renderer, &style)
            }
        }
        ass_set_selective_style_override_enabled(renderer, Int32(bits))
    }

    // MARK: Timings

    /// Queue only: the slowest frame since the last report, and how many went over a frame's time.
    private var slowest: (render: UInt64, compose: UInt64, pixels: Int) = (0, 0, 0)
    private var slowFrames = 0
    private var reportedAt: UInt64 = 0

    /**
     * Logs the frames libass and the blend took longer than a 24 Hz frame over (`[subtitles] slow`), at
     * most every 10 s, in the app menu's subtitle log, so heavy typesetting shows which part costs, as the
     * Android app counts its renders and blends.
     */
    private func noteTiming(render: UInt64, compose: UInt64, pixels: Int) {
        guard render + compose > Self.slowNanos else { return }
        slowFrames += 1
        if render + compose > slowest.render + slowest.compose { slowest = (render, compose, pixels) }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - reportedAt > 10_000_000_000 else { return }
        reportedAt = now
        EngineLogBook.note("[subtitles] slow: \(slowFrames) frames over \(Self.slowNanos / 1_000_000) ms; slowest libass \(slowest.render / 1_000_000) ms, blend \(slowest.compose / 1_000_000) ms, \(slowest.pixels / 1000)k pixels")
        slowFrames = 0
        slowest = (0, 0, 0)
    }

    private static let slowNanos: UInt64 = 42_000_000

    /**
     * Lays libass's pieces (shadows, outlines, then fills, each an alpha mask in one colour) over each
     * other into one premultiplied RGBA picture, with the Android app's blend (AssBlend.c).
     */
    private static func compose(_ first: UnsafeMutablePointer<ASS_Image>?) -> (image: CGImage, rect: CGRect)? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var node = first
        while let image = node?.pointee {
            if image.w > 0, image.h > 0, image.color & 0xff != 0xff {
                minX = min(minX, Int(image.dst_x))
                minY = min(minY, Int(image.dst_y))
                maxX = max(maxX, Int(image.dst_x) + Int(image.w))
                maxY = max(maxY, Int(image.dst_y) + Int(image.h))
            }
            node = image.next
        }
        guard minX < maxX, minY < maxY else { return nil }
        let width = maxX - minX
        let height = maxY - minY
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let data = context.data else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)

        node = first
        while let image = node?.pointee {
            defer { node = image.next }
            guard image.w > 0, image.h > 0, let bitmap = image.bitmap, image.color & 0xff != 0xff else { continue }
            let x0 = Int(image.dst_x) - minX
            let y0 = Int(image.dst_y) - minY
            aio_ass_blend(bitmap, image.w, image.h, image.stride, image.color,
                          pixels + y0 * rowBytes + x0 * 4, Int32(rowBytes))
        }
        guard let picture = context.makeImage() else { return nil }
        return (picture, CGRect(x: minX, y: minY, width: width, height: height))
    }
}

/// One cue's events, as the engine timed them, in seconds of the source's clock.
struct SubtitleCueEvent {
    let text: String
    let start: Double
    let end: Double
}
