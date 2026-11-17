import CoreImage
import Foundation
import ImageIO

/**
 * Pictures the page asks the app to draw down to a width, at
 * `aiostv://localhost/fit/<width>?u=<address>`: backdrops at the screen's width
 * (patches/web/0042), and every other artwork at the width its address asks for
 * (BridgeScript's FIT_IMAGES). The server
 * sends TMDB's original, often wider than 3000, for any backdrop asked over
 * 1280 wide, and WebKit holds each decoded at its full size: about three in
 * the hero ran the page's process out of memory with the artwork background
 * on. The page's own artwork workers can't help, as this WebKit doesn't start
 * them for the app's scheme.
 *
 * Here the original is fetched and ImageIO makes the smaller copy, decoding a
 * JPEG at the reduced size itself, so the whole picture is never held in
 * either process. One already no wider goes back as it came. All in the app's
 * process, which has the memory to spare.
 *
 * With `&blur=<radius>` (BridgeScript's SPOILER_ART), the copy is blurred here too, for the page's
 * "Blur episodes you haven't started", in place of the page's `filter: blur(12px)`, which WebKit
 * draws into a surface of its own at 2x for each picture. Blurred, a picture has no detail finer
 * than its blur, so it's made a third as wide, and WebKit scales it up: a ninth of the memory.
 */
enum ImageFit {
    static let prefix = "/fit/"

    /// How the fits went since launch, for the memory log.
    struct Counts {
        var drawn = 0
        var passed = 0
        var failed = 0
        var lastError = ""
    }

    private static let lock = NSLock()
    private static var counts = Counts()
    /**
     * Fitted pictures by address and width, the newest, as the hero comes back round to them and the
     * page's sweep puts released artwork back as it nears the screen again. Encoded, so a few MB.
     */
    private static var kept: [String: (data: Data, type: String)] = [:]
    private static var order: [String] = []
    private static var keptBytes = 0
    private static let keptMaxBytes = 32 << 20
    /// One at a time, so at most one picture is being made at once.
    private static let queue = DispatchQueue(label: "io.github.aiostreams.image-fit", qos: .userInitiated)
    /// Shared with ArtWash, so a title's art is fetched once for both.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        // Every picture on the page comes through here, so originals are kept on disk too, as the page's
        // cache settings say (ArtworkCache).
        configuration.urlCache = ArtworkCache.disk
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    static var current: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /**
     * The picture at `source` no wider than `width`, as `done(data, type)`, or `done(nil, nil)`.
     * With `blur`, blurred by that radius in pixels of a picture `width` wide.
     * A `width` of 0 (`/fit/full`, an address that names none) keeps it as it is: it comes through
     * here only to be kept in the artwork cache (ArtworkCache).
     */
    static func fit(_ source: URL, width: Int, blur: Double = 0, done: @escaping (Data?, String?) -> Void) {
        guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""), width >= 0 else {
            note(failed: "not a web address")
            return done(nil, nil)
        }
        let blur = blur.isFinite ? min(max(blur, 0), 200) : 0
        let key = blur > 0 ? "\(width) blur \(blur) \(source.absoluteString)" : "\(width) \(source.absoluteString)"
        if let hit = cached(key) { return done(hit.data, hit.type) }
        load(source, retried: false) { data, response, error in
            if let error {
                note(failed: error.localizedDescription)
                return done(nil, nil)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard let data, (200..<300).contains(status) else {
                note(failed: "HTTP \(status)")
                return done(nil, nil)
            }
            // A vector picture has no pixels to draw down, and ImageIO can't read it: it goes back
            // as it came. Answered as missing, the page gave up on a title's SVG logo and showed
            // its name instead.
            if isSVG(data, response) {
                keep(key, data, "image/svg+xml")
                note(drawn: false)
                return done(data, "image/svg+xml")
            }
            queue.async {
                guard let made = make(data, width: width, blur: blur) else {
                    note(failed: "couldn't read the picture")
                    return done(nil, nil)
                }
                keep(key, made.data, made.type)
                note(drawn: made.drawn)
                done(made.data, made.type)
            }
        }
    }

    /**
     * The download, tried once more a moment later where it couldn't connect or timed out: a
     * scroll asks for dozens at once, and a host can refuse some of a burst. The page loads one that
     * fails twice from its own address (BridgeScript's FIT_IMAGES).
     */
    private static func load(_ source: URL, retried: Bool,
                             done: @escaping (Data?, URLResponse?, Error?) -> Void) {
        session.dataTask(with: source) { data, response, error in
            let transient: Set<Int> = [
                NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            ]
            if let error = error as NSError?, error.domain == NSURLErrorDomain, transient.contains(error.code), !retried {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { load(source, retried: true, done: done) }
                return
            }
            done(data, response, error)
        }.resume()
    }

    /// Said so by its server, or by its own start, as a server may send it as anything.
    private static func isSVG(_ data: Data, _ response: URLResponse?) -> Bool {
        if response?.mimeType?.lowercased() == "image/svg+xml" { return true }
        guard let head = String(data: data.prefix(1024), encoding: .utf8)?.lowercased() else { return false }
        let start = head.drop { $0.isWhitespace || $0 == "\u{feff}" }
        return start.hasPrefix("<svg") || (start.hasPrefix("<?xml") && head.contains("<svg"))
            || (start.hasPrefix("<!doctype svg"))
    }

    /// How many times narrower a blurred copy is made than the width asked for.
    private static let blurShrink = 3
    /// Only touched on `queue`.
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    private static func make(_ data: Data, width: Int, blur: Double = 0) -> (data: Data, type: String, drawn: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelsWide = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelsWide > 0, pixelsHigh > 0
        else { return nil }
        let png = (CGImageSourceGetType(source) as String?) == "public.png"
        let type = png ? "image/png" : mime(CGImageSourceGetType(source) as String?)
        let blurring = blur > 0
        // No width asked: as wide as it is.
        let width = width > 0 ? width : pixelsWide
        if pixelsWide <= width, !blurring { return (data, type, false) }
        let target = blurring ? max(16, min(width, pixelsWide) / blurShrink) : width
        // ImageIO sizes a thumbnail by its longer side; the width is what's capped.
        let longest = Int((Double(max(pixelsWide, pixelsHigh)) * Double(target) / Double(pixelsWide)).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if blurring {
            // The page draws the copy `width` wide, so the radius shrinks with it.
            guard let blurred = blurred(image, radius: blur * Double(image.width) / Double(width)) else { return nil }
            image = blurred
        }
        let out = NSMutableData()
        // A PNG may be see-through; a backdrop otherwise is not.
        let format = png ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, format as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, png ? "image/png" : "image/jpeg", true)
    }

    /// Its edges spread outward rather than fading to clear, so a blurred card has no dark rim.
    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return blurContext.createCGImage(output, from: input.extent)
    }

    private static func mime(_ uti: String?) -> String {
        switch uti {
        case "public.jpeg": return "image/jpeg"
        case "org.webmproject.webp": return "image/webp"
        case "public.avif": return "image/avif"
        case "com.compuserve.gif": return "image/gif"
        default: return "image/jpeg"
        }
    }

    private static func cached(_ key: String) -> (data: Data, type: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = kept[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    private static func keep(_ key: String, _ data: Data, _ type: String) {
        lock.lock()
        defer { lock.unlock() }
        if let old = kept.updateValue((data, type), forKey: key) {
            keptBytes -= old.data.count
        } else {
            order.append(key)
        }
        keptBytes += data.count
        while keptBytes > keptMaxBytes, !order.isEmpty {
            if let gone = kept.removeValue(forKey: order.removeFirst()) { keptBytes -= gone.data.count }
        }
    }

    /// Drops the fitted copies kept in memory, as the page's artwork cache is cleared (ArtworkCache).
    static func forgetKept() {
        lock.lock()
        defer { lock.unlock() }
        kept.removeAll()
        order.removeAll()
        keptBytes = 0
    }

    private static func note(drawn: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if drawn { counts.drawn += 1 } else { counts.passed += 1 }
    }

    private static func note(failed why: String) {
        lock.lock()
        defer { lock.unlock() }
        counts.failed += 1
        counts.lastError = why
    }
}
