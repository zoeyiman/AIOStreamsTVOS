import AetherHost
import UIKit

/**
 * AetherEngine's video beneath, its subtitles over it, the web app over both,
 * and the bridge between them. The web side follows the working
 * aiostreams-tvos project: a WKWebView loaded at runtime, given the whole
 * screen, focused so the page's focus ring shows, and the remote taken at the
 * window and handed to the page as keys.
 */
final class MainViewController: UIViewController, RemoteReceiver {
    private let videoView = AetherPlayerView(frame: .zero)
    private let subtitleView = SubtitleOverlay(frame: .zero)
    /// The two above, full screen or where the page's mini player and trailer previews put them.
    private lazy var stage = VideoStage(video: videoView, subtitles: subtitleView)
    /// The hero's or a title page's backdrop at 4K, beneath the page (`tvos-backdrop`, BackdropStage).
    private let backdrop = BackdropStage()
    /// "Background from artwork"'s wash, beneath the backdrop (`tvos-wash`, WashStage).
    private let wash = WashStage()
    private var web: AIOWebView?
    private let status = UILabel()
    private var engine: AetherPlayer?
    private var player: PlayerChannel?
    private var pip: PictureInPicture?
    private let input = RemoteInput()
    private let storage = WebStorage()
    /// The page has said hello, so it takes Back.
    private var connected = false
    /// `aiostreams://` links, held until the page listens for them.
    private var links: [String] = []
    private var linksReady = false
    /// A held key's repeat the page hasn't finished with.
    private var repeatInFlight = false
    /// The page's latest errors (`web-error`), for the app menu.
    private var pageErrors: [String] = []
    private static let keptPageErrors = 8
    /// The page's garbage collected once its moves between pages settle (`collectPageGarbage`).
    private var collectTimer: Timer?
    private var lastCollected = Date.distantPast
    /// After the last move, so a run of moves isn't held up by a collection's pause.
    private static let collectAfterMove: TimeInterval = 3
    private static let collectAtMostEvery: TimeInterval = 10
    /// A newer release found as the app launched (UpdateCheck), until it's offered; and whether the page has loaded since.
    private var updateFound: String?
    private var updateChecked = false
    private var pageReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AppFolders.create()

        for pane in [videoView, subtitleView] as [UIView] {
            pane.isHidden = true
            pane.isUserInteractionEnabled = false
        }
        videoView.backgroundColor = .black
        // Both on one stage, which the page can draw small (`player-frame`, VideoStage).
        stage.view.frame = view.bounds
        stage.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(stage.view)
        stage.pictureInPicture = { [weak self] in self?.pip?.active == true }
        // Beneath the video too: a trailer plays only while the backdrop is put away.
        view.insertSubview(backdrop.view, at: 0)
        backdrop.reply = { [weak self] in self?.sendToPage($0) }
        // A new title's wash changes with its art, not before it (WashStage's `hold`).
        backdrop.artShown = { [weak self] in self?.wash.artReady() }
        wash.waitForArt = { [weak self] in self?.backdrop.awaitingArt ?? false }
        // Beneath everything: the page's background, which it stands in for.
        wash.view.frame = view.bounds
        wash.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(wash.view, at: 0)
        wash.reply = { [weak self] in self?.sendToPage($0) }

        status.frame = view.bounds.insetBy(dx: 160, dy: 160)
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        status.textColor = UIColor(white: 0.85, alpha: 1)
        status.font = .systemFont(ofSize: 36, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 0

        guard let root = WebApp.root else {
            view.addSubview(status)
            return showStatus("The web app is missing from this build. Run scripts/fetch-web.sh, then build again.")
        }
        let web = AIOWebView(frame: view.bounds, scheme: WebApp.scheme, root: root)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        view.addSubview(status)
        self.web = web
        stage.web = web
        backdrop.web = web
        backdrop.scrollView = web.scrollView
        guard web.available else {
            return showStatus("This version of tvOS has no web engine the app can use.")
        }
        web.userAgent = Identity.userAgent
        web.onMessage = { [weak self] in self?.receive($0) }
        web.onLoadFinished = { [weak self] in
            self?.status.isHidden = true
            self?.web?.focusPage()
        }
        web.onLoadFailed = { [weak self] error in
            self?.connected = false
            self?.showStatus("The page couldn't load.\n\(error)\n\nHold Play/Pause for options.")
        }
        web.onProcessEnded = { [weak self] url, reason in
            self?.pageEnded(at: url, reason: reason)
        }
        web.onResponsiveness = { [weak self] responsive in
            MemoryLog.pageResponsive(responsive, playing: self?.player?.playing == true)
        }
        MemoryLog.webMB = { [weak web] in
            guard let mb = web?.webProcessMB, mb >= 0 else { return nil }
            return mb
        }
        MemoryLog.gpuMB = { [weak web] in
            guard let mb = web?.gpuProcessMB, mb >= 0 else { return nil }
            return mb
        }
        MemoryLog.routes = { [weak web] in (web?.webProcessRoute, web?.gpuProcessRoute) }
        MemoryLog.startSampling()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated {
                MemoryLog.warning(playing: self?.player?.playing == true)
                // tvOS is short of memory, and the page's process is the most likely to be ended: its
                // artwork near the screen only, until it's scrolled back to.
                self?.callTV("trim()")
            }
        }
        web.onOpenURL = { [weak self] in self?.open($0) }
        web.onServed = { path, status, _ in
            if status != 200 { NSLog("[web] %ld for %@", status, path) }
        }
        web.thumbnailAtPath = { ThumbnailStore.image($0) }
        web.fitImage = { source, width, blur, done in ImageFit.fit(source, width: width, blur: blur, done: done) }
        web.washImage = { source, done in ArtWash.make(source) { done($0?.png, $0?.tint, $0?.panel) } }

        startPlayer()
        setUpInput()
        loadPage()
        // Once a launch: not as the app comes back from the background, nor as the page loads again.
        UpdateCheck.newer(than: Identity.version) { [weak self] version in
            guard let self else { return }
            self.updateFound = version
            self.updateChecked = true
            self.offerUpdate()
        }
    }

    /**
     * Cancels tvOS's safe area for the whole screen: the page lays out edge to
     * edge and keeps its own margins, as on Android TV.
     */
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let safe = view.safeAreaInsets
        let added = additionalSafeAreaInsets
        let cancel = UIEdgeInsets(
            top: -(safe.top - added.top), left: -(safe.left - added.left),
            bottom: -(safe.bottom - added.bottom), right: -(safe.right - added.right)
        )
        if added != cancel { additionalSafeAreaInsets = cancel }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        web?.focusPage()
    }

    // MARK: Page

    /**
     * The bridge script carries the app's copy of the page's storage, so it's made fresh for each load,
     * a reload after the page's process ended included. `url` is where the page was, if it's one of the app's.
     */
    private func loadPage(at url: URL? = nil) {
        guard let web else { return }
        connected = false
        linksReady = false
        showStatus("Loading AIOStreams…")
        web.setStartScript(BridgeScript.make(
            version: "\(Identity.version)-tvos",
            device: Identity.device,
            deviceId: Identity.deviceId,
            hours24: Identity.hours24,
            storage: storage.json
        ))
        let ours = url.flatMap { $0.scheme?.lowercased() == WebApp.scheme ? $0 : nil }
        // `loadURL:` in Objective-C; Swift names it `load(_:)`.
        web.load(ours ?? WebApp.startURL)
    }

    /// When the page's process last ended, newest last, to tell a page that ends again as it loads.
    private var pageEnds: [Date] = []
    /// An end this soon after the last one counts as the page failing as it loads.
    private static let quickEnd: TimeInterval = 30
    /// How long a third quick end in a row waits before loading home again.
    private static let retryDelay: TimeInterval = 5

    /**
     * The page's process ended. It loads again where it was; ended again within `quickEnd`, it
     * loads at the start, as the page it was on may be what takes it to its limit as it loads (a
     * Jetsam report showed 13 ends in 26 s). A third quick end in a row waits `retryDelay` and
     * loads home again, so the reloads don't come back to back. None of these show a notice.
     */
    private func pageEnded(at url: URL?, reason: AIOPageEnd) {
        // The page that set a frame is gone: the video fills the screen and the page is whole again.
        stage.place(nil)
        backdrop.reset()
        wash.reset()
        let now = Date()
        pageEnds = pageEnds.filter { now.timeIntervalSince($0) < 10 * Self.quickEnd } + [now]
        var quick = 0
        for (earlier, later) in zip(pageEnds.dropLast(), pageEnds.dropFirst()).reversed() {
            guard later.timeIntervalSince(earlier) < Self.quickEnd else { break }
            quick += 1
        }
        let place = url.map { u in
            u.path + (u.query.map { "?\($0)" } ?? "") + (u.fragment.map { "#\($0)" } ?? "")
        }
        MemoryLog.pageEnded(playing: player?.playing == true, reason: reason, at: place)
        // No notice: the end and its cause go to the memory log, which the app's log share carries.
        switch quick {
        case 0:
            loadPage(at: url)
        case 1:
            loadPage()
        default:
            // Still ending as it loads at home: wait a moment, so tvOS can free memory, and try home again.
            pageEnds = []
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.loadPage()
            }
        }
    }

    private func showStatus(_ text: String) {
        status.text = text
        status.isHidden = false
    }

    /// A notice that clears itself.
    private func flashStatus(_ text: String) {
        showStatus(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status.text == text { self?.status.isHidden = true }
        }
    }

    private func sendToPage(_ message: Message) {
        guard let json = JSON.string(message) else { return }
        web?.evaluateJavaScript("window.__aioReceive&&window.__aioReceive(\(json))")
    }

    /// What the page was last told about the player's picture-in-picture button.
    private var pipButtonShown = false

    /// Shown while a video plays on the engine's AVPlayer and the page's Picture-in-picture setting is on.
    private func updatePipButton() {
        let offered = pip?.offered == true
        guard offered != pipButtonShown else { return }
        pipButtonShown = offered
        callTV("pip(\(offered))")
    }

    private func callTV(_ call: String) {
        web?.evaluateJavaScript("window.__aioTV&&window.__aioTV.\(call)")
    }

    private func jsString(_ text: String) -> String {
        JSON.string([text]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: Player

    private func startPlayer() {
        do {
            let engine = try AetherPlayer(view: videoView, subtitles: subtitleView)
            self.engine = engine
            // Match Content's HDR10, HLG, Dolby Vision and frame rate are the engine's own to ask tvOS for.
            let player = PlayerChannel(
                player: engine,
                subtitlesDir: AppFolders.subtitles,
                send: { [weak self] message in self?.sendToPage(message) },
                showVideo: { [weak self] shown in
                    self?.videoView.isHidden = !shown
                    self?.subtitleView.isHidden = !shown
                }
            )
            self.player = player
            player.nowPlaying.onSeek = { [weak self] in self?.seekedFromSystem() }
            let pip = PictureInPicture(player: engine, channel: player, send: { [weak self] in self?.sendToPage($0) })
            pip.failed = { [weak self] in self?.flashStatus($0) }
            pip.window = { [weak self] in self?.view.window }
            pip.ended = { [weak self] in
                self?.web?.focusPage()
                self?.updatePipButton()
                // A frame the page set meanwhile shows again, with its hole.
                self?.stage.refresh()
            }
            player.onStopped = { [weak pip] in pip?.stop() }
            // The engine's AVPlayer layer is there once a video has loaded.
            player.onPlayerEvent = { [weak self] in self?.updatePipButton() }
            self.pip = pip
        } catch {
            NSLog("[app] AetherEngine did not start: %@", String(describing: error))
        }
    }

    // MARK: Remote

    var takesRemote: Bool { presentedViewController == nil && web?.available == true }

    func remotePress(_ press: UIPress) {
        input.press(press)
    }

    func remoteTouches(_ touches: Set<UITouch>) {
        input.touches(touches)
    }

    func ownsPress(_ press: UIPress) -> Bool {
        input.owns(press)
    }

    /// Anything the app opens over the page (the search keyboard, the app menu, alerts) takes the
    /// remote from it: a held arrow stops repeating into the page underneath first.
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        input.interrupt()
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    private func setUpInput() {
        input.keyDown = { [weak self] key, repeated in
            guard let self else { return }
            let call = "window.__aioTV&&window.__aioTV.down(\(self.jsString(key)),\(repeated))"
            guard repeated else {
                self.web?.evaluateJavaScript(call)
                return
            }
            // A held key repeats at the page's pace: while the page is still on the last repeat (laying out
            // a new row, say), the next is dropped rather than queued, so focus doesn't run on in a burst.
            guard !self.repeatInFlight, let web = self.web else { return }
            self.repeatInFlight = true
            web.evaluateJavaScript(call) { [weak self] in self?.repeatInFlight = false }
        }
        input.keyUp = { [weak self] key in
            guard let self else { return }
            self.callTV("up(\(self.jsString(key)))")
        }
        input.back = { [weak self] in
            guard let self else { return }
            if self.connected { self.sendToPage(["type": "back"]) } else { self.leaveApp() }
        }
        input.menu = { [weak self] in self?.showAppMenu() }
    }

    private func leaveApp() {
        player?.change(Change(paused: true))
        suspendApp()
    }

    // MARK: The app's own screens

    /// With how the video and its sound play, to see why HDR or Atmos doesn't reach the TV.
    private func showAppMenu() {
        guard presentedViewController == nil else { return }
        // In steps: as one expression, the compiler gives up type-checking it.
        var lines: [String] = [
            "App commit: \(WebApp.appCommit)",
            "App \(Identity.version) · web app \(WebApp.commit) · \(storage.keyCount) saved keys", "",
        ]
        if !pageErrors.isEmpty {
            lines.append("Page errors, newest last:")
            lines += pageErrors
            lines.append("")
        }
        // What the app draws beneath the page now, beside the page's marks in the memory lines below.
        lines.append("Backdrop: \(backdrop.summary) · wash: \(wash.view.isHidden ? "none" : "shown")")
        lines.append("Video: \(stage.summary), \(videoView.isHidden ? "video view hidden" : "video view shown")")
        lines.append("")
        lines += AppAnswers.videoLines(player: engine, window: view.window)
        lines.append("")
        lines += MemoryLog.report
        let held = AetherPlayer.heldSourceConnection
        let priming = AudioOutput.primerEnabled
        let report = lines.joined(separator: "\n")
        let menu = AppMenu(title: "AIOStreams", text: report, actions: [
            AppMenu.Action(title: "Open the log on a phone…", destructive: false) { [weak self] in
                self?.shareLog(report)
            },
            AppMenu.Action(title: "Play a test video…", destructive: false) { [weak self] in self?.askTestVideo() },
            AppMenu.Action(title: "Reload", destructive: false) { [weak self] in self?.loadPage() },
            AppMenu.Action(title: held ? "Use ranged source requests" : "Hold one source connection", destructive: false) {
                [weak self] in
                AetherPlayer.heldSourceConnection = !held
                self?.flashStatus(held
                    ? "Ranged source requests from the next video"
                    : "One held source connection from the next video")
            },
            AppMenu.Action(title: priming ? "Turn the Dolby primer off" : "Turn the Dolby primer on", destructive: false) {
                [weak self] in
                AudioOutput.primerEnabled = !priming
                self?.flashStatus(priming
                    ? "Dolby primer off from the next video"
                    : "Dolby primer on from the next video: for surround that plays as stereo")
            },
            AppMenu.Action(title: "Reset the app's data", destructive: true) { [weak self] in self?.confirmReset() },
            AppMenu.Action(title: "Close", destructive: false) {},
        ])
        // However it closed: an action, Close or Menu.
        menu.closed = { [weak self] in self?.web?.focusPage() }
        present(menu, animated: true)
    }

    /// The app menu's `report` as a text file a phone on the same network opens (`LogShareScreen`).
    private func shareLog(_ report: String) {
        guard presentedViewController == nil else { return }
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let header = "AIOStreams for Apple TV \(Identity.version), tvOS \(UIDevice.current.systemVersion), \(when)"
        let screen = LogShareScreen(text: header + "\n\n" + report + "\n")
        screen.closed = { [weak self] in self?.web?.focusPage() }
        present(screen, animated: true)
    }

    /**
     * The newer release found as the app launched, once the page has loaded. Told of once: shown, it
     * isn't again. With something else on screen by then (a video, a dialog), it waits for the next
     * launch rather than come up over it.
     */
    private func offerUpdate() {
        guard updateChecked, pageReady else { return }
        guard let version = updateFound else { return }
        updateFound = nil
        guard presentedViewController == nil, player?.playing != true else { return }
        UpdateCheck.markShown(version)
        let alert = UIAlertController(
            title: "Update available",
            message: "AIOStreams for Apple TV \(version) is out; this is \(Identity.version). "
                + "Update it in the app you sideload with, or download it from \(UpdateCheck.releases).",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true)
    }

    private func confirmReset() {
        let confirm = UIAlertController(
            title: "Reset the app's data?",
            message: "This signs you out and forgets your servers and settings on this Apple TV.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.storage.clear()
            self.web?.removeAllWebData { [weak self] in self?.loadPage() }
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(confirm, animated: true)
    }

    /**
     * tvOS has no keyboard for a web page, so a field the page asks for opens
     * the system's, with dictation. Most fields get the search keyboard over
     * the page, typing straight into the field; passwords and PINs get the
     * alert, which keeps them hidden and sends a PIN's form on Done.
     */
    /// `rgb(r, g, b)` as the page sends its colour (read off a canvas pixel), or nil.
    static func pageColor(_ text: String) -> UIColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("rgb"), let open = trimmed.firstIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"), open < close else { return nil }
        let parts = trimmed[trimmed.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count >= 3, parts.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// The page's colour, and the wash: the page's copy, or the one drawn here beneath it (WashStage).
    private func keyboardLook(_ message: Message) -> KeyboardLook {
        var look = KeyboardLook(background: message.text("background"), wash: message.text("wash"))
        if look.wash == nil, !wash.view.isHidden { look.wash = wash.image }
        return look
    }

    private func showKeyboard(_ message: Message) {
        guard presentedViewController == nil else {
            if keyboard == nil { callTV("done(false, false)") }
            return
        }
        if message.flag("secure") == true || message.flag("numeric") == true { return showKeyboardAlert(message) }
        let keyboard = SearchKeyboard(
            text: message.text("value") ?? "",
            prompt: message.text("label") ?? "",
            look: keyboardLook(message),
            keyboardType: message.flag("email") == true ? .emailAddress : message.flag("url") == true ? .URL : .default,
            onChange: { [weak self] text in
                guard let self else { return }
                self.callTV("input(\(self.jsString(text)))")
            },
            onClose: { [weak self] submit, moveToResults in
                guard let self else { return }
                self.keyboard = nil
                self.callTV("done(\(submit), \(moveToResults))")
                self.web?.focusPage()
            }
        )
        self.keyboard = keyboard
        present(keyboard.controller, animated: true)
    }

    /// The keyboard open over the page, kept until it closes.
    private var keyboard: SearchKeyboard?

    private func showKeyboardAlert(_ message: Message) {
        let label = message.text("label") ?? ""
        let alert = UIAlertController(title: label.isEmpty ? "Enter text" : label, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = message.text("value") ?? ""
            field.isSecureTextEntry = message.flag("secure") == true
            if message.flag("email") == true { field.keyboardType = .emailAddress }
            if message.flag("url") == true { field.keyboardType = .URL }
            // A PIN gets the digits-only keyboard.
            if message.flag("numeric") == true { field.keyboardType = .numberPad }
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            // A PIN is the last thing its form asks for, so Done sends it.
            let submit = message.flag("numeric") == true
            self.callTV("type(\(self.jsString(text)),\(submit))")
            self.web?.focusPage()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true) { [weak alert] in
            // Straight to the keyboard rather than the alert's field.
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    // MARK: Links

    /// A link out of the page: an `aiostreams://` link for the page, or another app's, such as a player's.
    private func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "aiostreams" { return receiveLink(url.absoluteString) }
        // A TV has no browser for a web link.
        if scheme == "http" || scheme == "https" { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            self?.flashStatus("Couldn't open the player. Check that the app for \(scheme):// links is installed.")
        }
    }

    /// From the system, or a link in the page.
    func receiveLink(_ url: String) {
        guard url.lowercased().hasPrefix("aiostreams://") else { return }
        links.append(url)
        sendLinks()
    }

    private func sendLinks() {
        while linksReady, !links.isEmpty {
            sendToPage(["type": "link", "url": links.removeFirst()])
        }
    }

    // MARK: Messages

    private func receive(_ message: Message) {
        guard let type = message.text("type") else { return }
        // Before the player shows its picture, or after it stops, so the stage knows a trailer's ended.
        if type == "player-load" { stage.loading() }
        if type == "player-stop" { stage.stopped() }
        if player?.handle(type, message) == true {
            // A load, a stop or a new item may show or hide the player's picture-in-picture button.
            updatePipButton()
            return
        }
        switch type {
        case "hello":
            connected = true
            status.isHidden = true
            // A page that loaded again knows nothing of a frame the last one set.
            stage.place(nil)
            backdrop.reset()
            view.backgroundColor = .black
            wash.reset()
            web?.focusPage()
            pipButtonShown = false
            updatePipButton()
            if !pageReady {
                pageReady = true
                offerUpdate()
            }
        case "tvos-pip":
            // The player's picture-in-picture button, which the bridge script adds.
            pip?.start()
        case "player-frame":
            // The page's mini player docked in a preview, or a trailer playing by itself in a card, the hero
            // or a title page: the video in that box, or the whole screen again for none (VideoStage).
            stage.place(VideoFrame.from(message, webWidth: web?.bounds.width ?? view.bounds.width))
            // A trailer that goes from its box to the whole screen, or back, gets its subtitles picked again.
            player?.framed(message.object("frame") != nil)
        case "app-info":
            sendToPage(AppAnswers.appInfo())
        case "log":
            // The page's `appLog`, into the app's log. Its subtitle sync lines (`[sync]`, patches/web/0025 and 0026) also go
            // into the app menu's report, beside the app's own; the rest, such as live recovery's, would crowd it.
            let line = String((message.text("message") ?? "").prefix(400))
            if line.hasPrefix("[sync]") {
                EngineLogBook.note("[page] \(line)")
            } else {
                NSLog("[page] %@ %@", message.text("level") ?? "info", line)
            }
        case "player-engine":
            // The page asks for its engine choice; this app has only AetherEngine. Like the Android app's
            // ExoPlayer, it plays on the system's decoders and has no mpv options, so the page treats it as
            // that: it hides mpv's settings and asks for ExoPlayer-style statistics (`player-stats`).
            sendToPage(["type": "player-engine", "name": "exoplayer"])
        case "fullscreen":
            sendToPage(["type": "fullscreen", "value": true])
        case "levels":
            sendToPage(["type": "levels", "volume": 1.0, "brightness": 1.0])
        case "links-ready":
            linksReady = true
            sendLinks()
        case "exit":
            leaveApp()
        case "tvos-storage":
            storage.apply(message)
        case "watch-next":
            // Continue Watching and Next Up, for the Top Shelf.
            TopShelf.publish(message)
        case "tvos-keyboard":
            showKeyboard(message)
        case "mpv-config", "mpv-config-save":
            sendToPage(["type": "mpv-config", "text": MPVConfig.text])
        case "diagnostics":
            sendToPage(AppAnswers.diagnostics(
                player: engine, window: view.window,
                web: message.text("web"), server: message.text("server")
            ))
        case "licenses":
            sendToPage(AppAnswers.licenses)
        case "crash-report":
            sendToPage(["type": "crash-report"])
        case "update-check", "update-apply":
            sendToPage(AppAnswers.updateState)
        case "youtube-resolve":
            // A trailer: its stream, for the player. Without one the page opens the link, which the YouTube app takes.
            let request = message.text("request") ?? ""
            YouTube.resolve(message.text("id") ?? "") { [weak self] url in
                self?.sendToPage(["type": "youtube-resolved", "request": request, "url": nullable(url)])
            }
        case "voice-search":
            // Dictation is on the keyboard's microphone; the page doesn't offer its own here.
            sendToPage(["type": "voice-result", "text": NSNull(), "error": "failed"])
        case "web-error":
            let text = message.text("message") ?? ""
            NSLog("[page] %@", text)
            // Kept for the app menu: a page stuck on its splash shows nothing else of why.
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            pageErrors.append("\(time): \(text.prefix(600))")
            if pageErrors.count > Self.keptPageErrors { pageErrors.removeFirst(pageErrors.count - Self.keptPageErrors) }
        case "tvos-backdrop":
            // The hero's or a title page's backdrop, drawn here at 4K, or put away (patches/web/0048).
            backdrop.handle(message)
        case "tvos-wash":
            // "Background from artwork"'s wash, drawn here beneath the page, or none (patches/web/0050).
            wash.handle(message)
        case "tvos-page-color":
            // The page's colour, drawn here beneath the wash, the backdrop and the page, whose own
            // background is then clear (patches/web/0058), so the backdrop shows through it with no hole.
            let text = message.text("color")
            guard let text, let color = Self.pageColor(text) else {
                view.backgroundColor = .black
                if text != nil { sendToPage(["type": "tvos-page-color", "color": text ?? "", "drawn": false]) }
                break
            }
            view.backgroundColor = color
            sendToPage(["type": "tvos-page-color", "color": text, "drawn": true])
        case "tvos-page-stats":
            MemoryLog.pageStats(message)

        case "tvos-page-moved":
            MemoryLog.pageMoved(from: message.text("from") ?? "?", to: message.text("to") ?? "?")
            collectAfterMoves()
        default:
            // Downloads, keyboard completions and the like have no Apple TV part.
            break
        }
    }

    /**
     * The pages the page took down are collected some seconds after its moves stop, rather than
     * when JavaScriptCore gets round to it: they piled up by the thousand otherwise, and tvOS ended
     * the page's process at its own limit before the system was short enough to warn WebKit.
     */
    private func collectAfterMoves() {
        collectTimer?.invalidate()
        let at = max(Date().addingTimeInterval(Self.collectAfterMove),
                     lastCollected.addingTimeInterval(Self.collectAtMostEvery))
        collectTimer = Timer.scheduledTimer(withTimeInterval: max(0, at.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let web = self.web else { return }
                self.lastCollected = Date()
                MemoryLog.pageGarbageCollected(web.collectPageGarbage())
            }
        }
    }

    // MARK: Test video

    /// A video from a URL typed in the app menu plays in the page's own player, with its controls
    /// (`patches/web/0006-test-video-page.patch`), reached by an `aiostreams://test-video` link.
    private static let testURLKey = "debug.testVideoURL"

    private func askTestVideo() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Play a test video",
            message: "An http(s) link to a video file or an HLS playlist. It plays in the page's player, with its controls and settings; Back stops it.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = UserDefaults.standard.string(forKey: Self.testURLKey) ?? ""
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self, weak alert] _ in
            let text = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.startTestVideo(text)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true) { [weak alert] in
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    private func startTestVideo(_ url: String) {
        guard PlayerProtocol.isWebURL(url) else {
            web?.focusPage()
            return flashStatus("That isn't an http(s) link.")
        }
        // The page opens it once it's loaded and listening for links; one with a video open closes that first.
        guard connected else {
            web?.focusPage()
            return flashStatus("The page hasn't loaded yet.")
        }
        UserDefaults.standard.set(url, forKey: Self.testURLKey)
        // The link's value is decoded once by the page, so everything but unreserved characters is escaped.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let value = url.addingPercentEncoding(withAllowedCharacters: unreserved) ?? url
        receiveLink("aiostreams://test-video?url=\(value)")
        web?.focusPage()
    }

    // MARK: App state

    func appWillResignActive() {
        storage.save()
        input.stopRepeating()
        // Presses down now end out of the app's sight.
        input.forgetPresses()
        pip?.appWillResignActive()
        // The picture-in-picture window keeps playing over the Home screen.
        if pip?.active != true {
            player?.change(Change(paused: true))
            pausedForOverlay = player?.playing == true
            overlayGeneration += 1
        }
    }

    func appDidEnterBackground() {
        // Gone to the Home screen or another app, not Siri over the video: it stays paused.
        pausedForOverlay = false
        pip?.appDidEnterBackground()
    }

    /// The player opens a video again that tvOS made it let go of in the background (`AetherPlayer`);
    /// a picture-in-picture window comes back into the app.
    func appDidBecomeActive() {
        pip?.appDidBecomeActive()
        web?.focusPage()
        // Siri's seek can come just after it closes, so the pause is remembered a moment longer.
        let generation = overlayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySeekWait) { [weak self] in
            guard let self, generation == self.overlayGeneration else { return }
            self.pausedForOverlay = false
        }
    }

    /**
     * Siri, or anything else tvOS draws over the app, takes the app's focus, which pauses the video
     * (`appWillResignActive`), and a seek Siri was asked for ("go to 30 minutes") then landed paused.
     * This is set while a video is loaded and the app hasn't gone to the background since it lost its
     * focus, and a seek from the system then plays the video once the page has seeked
     * (`seekedFromSystem`), whether it played or was paused before Siri.
     */
    private var pausedForOverlay = false
    private var overlayGeneration = 0
    /// How long after the app gets its focus back a seek from Siri still plays the video.
    private static let overlaySeekWait: TimeInterval = 3

    /// A seek or skip from Siri or the system's Now Playing controls, already sent to the page.
    private func seekedFromSystem() {
        guard pausedForOverlay else { return }
        pausedForOverlay = false
        player?.playAfterNextSeek()
    }
}
