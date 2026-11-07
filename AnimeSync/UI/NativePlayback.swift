import SwiftUI
import AVKit
import Combine
import CoreMedia

/// Only hides while video is actually playing. A revision fences a completed
/// old timer even when its sleeper ignores cancellation during a UI transition.
@MainActor final class PlaybackToolbarState: ObservableObject {
    @Published private(set) var visible = true
    private var playing = false
    private var active = false
    private var presenting = false
    private var voiceOver = false
    private var revision: UInt64 = 0
    private var hideTask: Task<Void,Never>?
    private let sleep: (UInt64) async throws -> Void
    init(sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) { self.sleep = sleep }
    func update(playing: Bool,active: Bool,presenting: Bool,voiceOver: Bool) {
        let changed = self.playing != playing || self.active != active || self.presenting != presenting || self.voiceOver != voiceOver
        self.playing = playing; self.active = active; self.presenting = presenting; self.voiceOver = voiceOver
        if !canHide { cancel(); visible = true }
        else if changed { reveal() }
    }
    func reveal() {
        visible = true; cancel()
        guard canHide else { return }
        let captured = revision, sleep = sleep
        hideTask = Task { [weak self] in
            do {
                try await sleep(4_000_000_000)
                guard !Task.isCancelled, let self, self.revision == captured, self.canHide else { return }
                self.visible = false; self.hideTask = nil
            } catch { }
        }
    }
    func stop() { active = false; cancel(); visible = true }
    private var canHide: Bool { playing && active && !presenting && !voiceOver }
    private func cancel() { revision &+= 1; hideTask?.cancel(); hideTask = nil }
}

enum NativeCaptionPolicy {
    static func isEnglish(_ language: String) -> Bool {
        let value = language.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "en" || value == "english" || value.hasPrefix("en-") || value.hasPrefix("en_")
    }
    static func automaticExternal(_ sources: [SubtitleSource],embeddedLanguages: [String],automatic: Bool) -> SubtitleSource? {
        guard automatic, !embeddedLanguages.contains(where: isEnglish) else { return nil }
        return sources.first(where: { isEnglish($0.language) }) ?? (embeddedLanguages.isEmpty ? sources.first : nil)
    }
}

@MainActor final class NativePlaybackModel: ObservableObject, Identifiable {
    let id = UUID()
    let metadata: AnimeMetadata
    let source: MediaSource
    @Published private(set) var subtitles: [SubtitleSource] = []
    let player = AVPlayer()
    let sync: SyncService
    let fixture: Bool
    @Published var message = "Loading episode…"
    @Published var videoReady = false
    #if DEBUG
    @Published private(set) var qaPosition: TimeInterval = 0
    #endif
    @Published var captionText = ""
    @Published var captionSize: Double { didSet { if !fixture { UserDefaults.standard.set(captionSize,forKey: "caption.size") }; applyStyles() } }
    @Published var captionMargin: Double { didSet { if !fixture { UserDefaults.standard.set(captionMargin,forKey: "caption.margin") }; applyStyles() } }
    @Published var originalStyles: Bool { didSet { if !fixture { UserDefaults.standard.set(originalStyles,forKey: "caption.original") }; applyStyles() } }
    @Published var captionDelay: Double = 0 { didSet { refreshCaption() } }
    @Published var captionSelection = "automatic"
    @Published var embeddedOptions: [AVMediaSelectionOption] = []
    @Published var isStarting = false
    @Published private(set) var isSeeking = false
    @Published private(set) var handoffInProgress = false
    private(set) var lease: PlaybackLease?
    private var mediaBridge: MediaBridge?
    private var ticks: Any?
    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var invalidation: AnyCancellable?
    private var cueTask: Task<Void,Never>?
    private let captionTransport: HTTPTransport
    private var subtitleEpoch: UInt64 = 0
    private var embeddedTracksResolved = false
    private var automaticCaptions = true
    private struct SubtitleRequestIdentity: Equatable {
        let url: URL
        let headers: [String:String]
        init(_ source: SubtitleSource) { url = source.url; headers = MediaBridgePolicy.headers(source.headers) }
    }
    private var activeSubtitleRequest: SubtitleRequestIdentity?
    private var startTask: Task<Void,Never>?
    private var pendingGeneration: Int64?
    private var explicitPosition: TimeInterval?
    private let clock: (() -> (position: TimeInterval, duration: TimeInterval))?
    private let seekOperation: ((AVPlayer, TimeInterval) async -> Void)?
    private var resumeOnForeground = false
    private var startingEpoch: UInt64 = 0
    private var restoring = false
    private var disposed = false
    private var closing = false
    private var localOnly = false
    private var userScrubbing = false
    private var scrubDeadline: TimeInterval = 0
    private var positionBeforeScrub: TimeInterval?
    private var controlSeekRevision: UInt64 = 0
    private var embeddedControlMargin: Double = 0
    private var cues: [SubtitleCue] = []
    private var periodicCount = 0
    var onFallback: (() -> Void)?
    var onClose: (() -> Void)?
    var position: TimeInterval { let x = clock?().position ?? player.currentTime().seconds; return x.isFinite ? max(0,x) : 0 }
    var duration: TimeInterval { let x = clock?().duration ?? player.currentItem?.duration.seconds ?? 0; return x.isFinite ? max(0,x) : 0 }
    var canSeek: Bool { !disposed && !closing && videoReady && player.currentItem != nil && duration > 0 && !restoring && !isStarting && !handoffInProgress && !isSeeking }

    init(metadata: AnimeMetadata, source: MediaSource, subtitles: [SubtitleSource], sync: SyncService, fixture: Bool = false, position: TimeInterval? = nil, generation: Int64? = nil, clock: (() -> (position: TimeInterval, duration: TimeInterval))? = nil, captionTransport: HTTPTransport? = nil, seekOperation: ((AVPlayer, TimeInterval) async -> Void)? = nil) {
        self.metadata = metadata; self.source = source; self.sync = sync; self.fixture = fixture
        #if DEBUG
        if fixture {
            self.subtitles = [SubtitleSource(url: QACaptionTransport.url,label: "Fixture captions",language: "en")]
            self.captionTransport = captionTransport ?? QACaptionTransport()
        } else {
            self.subtitles = subtitles; self.captionTransport = captionTransport ?? CoreHTTPTransport()
        }
        #else
        self.subtitles = subtitles; self.captionTransport = captionTransport ?? CoreHTTPTransport()
        #endif
        self.explicitPosition = position; self.pendingGeneration = generation; self.clock = clock; self.seekOperation = seekOperation
        captionSize = fixture ? 22 : UserDefaults.standard.object(forKey: "caption.size") as? Double ?? 22
        captionMargin = fixture ? 0.1 : UserDefaults.standard.object(forKey: "caption.margin") as? Double ?? 0.1
        originalStyles = fixture ? false : UserDefaults.standard.bool(forKey: "caption.original")
        player.isMuted = fixture; player.allowsExternalPlayback = false
        observers.append(player.observe(\.rate, options: [.new]) { [weak self] _, change in Task { @MainActor in self?.rateChanged(change.newValue ?? 0) } })
        ticks = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25,preferredTimescale: 600),queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.disposed else { return }
                self.refreshCaption()
                #if DEBUG
                if self.fixture {
                    let realPosition = self.player.currentTime().seconds
                    if realPosition.isFinite {
                        let second = floor(max(0, realPosition))
                        if second != self.qaPosition { self.qaPosition = second }
                    }
                }
                #endif
                self.periodicCount += 1
                if self.periodicCount % 20 == 0 { await self.save() }
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,object: nil,queue: .main) { [weak self] note in Task { @MainActor in
            guard let self, !self.disposed, !self.closing, note.object as AnyObject? === self.player.currentItem else { return }
            let epoch = self.startingEpoch, item = self.player.currentItem, captured = self.lease
            await self.save(ended: true)
            guard !self.disposed, !self.closing, self.startingEpoch == epoch,
                  self.player.currentItem === item, self.lease === captured, self.player.rate == 0 else { return }
            self.release(); self.message = "Episode finished"
        } })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,object: nil,queue: .main) { [weak self] _ in Task { @MainActor in await self?.background() } })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped,object: nil,queue: .main) { [weak self] note in
            // The main-queue notification is handled inline: deferring to a Task
            // could observe restoring=false after our own programmatic seek.
            MainActor.assumeIsolated { self?.pausedTimeJump(note.object as AnyObject?) }
        })
    }
    func prepare() async {
        guard !disposed, !closing, player.currentItem == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let bridge = try await MediaBridge(source: source)
            guard !disposed, !closing else { bridge.stop(); return }; mediaBridge = bridge
            let item = AVPlayerItem(url: bridge.url)
            observers.append(item.observe(\.status,options: [.new]) { [weak self] item, _ in Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.player.pause(); self.message = "This source could not play. Try another source or the website player."; self.release() }
            } })
            player.replaceCurrentItem(with: item); applyStyles()
            Task { [weak self] in await self?.readEmbeddedTracks(item) }
            await play(explicit: true,expectedGeneration: pendingGeneration)
        } catch { message = error.localizedDescription }
    }
    private func readEmbeddedTracks(_ item: AVPlayerItem) async {
        do {
            let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !disposed, !closing, player.currentItem === item else { return }
            embeddedOptions = group?.options ?? []
            embeddedTracksResolved = true
            guard automaticCaptions else { return }
            if let group, let english = group.options.first(where: { NativeCaptionPolicy.isEnglish($0.extendedLanguageTag ?? $0.locale?.identifier ?? "") }) {
                subtitleEpoch &+= 1; cueTask?.cancel(); cues = []; captionText = ""; captionSelection = "automatic"; activeSubtitleRequest = nil
                item.select(english,in: group)
            } else { selectAutomaticExternal() }
        } catch {
            guard !disposed, !closing, player.currentItem === item else { return }
            embeddedTracksResolved = true
            selectAutomaticExternal()
        }
    }
    private func rateChanged(_ rate: Float) {
        guard !disposed, rate == player.rate else { return }
        if closing { if rate > 0 { player.pause() }; return }
        if handoffInProgress {
            if rate > 0 { restoring = true; player.pause(); restoring = false }
            return
        }
        guard !restoring, !isStarting else { return }
        if rate > 0, lease == nil, !localOnly {
            restoring = true; player.pause(); restoring = false
            startTask?.cancel(); startTask = Task { [weak self] in await self?.play(explicit: true) }
        } else if rate == 0, lease != nil, player.timeControlStatus == .paused {
            let captured = lease, epoch = startingEpoch
            Task { [weak self] in
                guard let self else { return }
                await self.save()
                // Play may resume while the save waits for the network. Keep that
                // active session; its Play event already observed the same lease.
                if !self.disposed, self.startingEpoch == epoch, self.player.rate == 0,
                   self.player.timeControlStatus == .paused, self.lease === captured { self.release() }
            }
        }
    }
    func play(explicit: Bool, expectedGeneration: Int64? = nil) async {
        guard !disposed, !closing, !isStarting, !isSeeking, !handoffInProgress else { return }
        isStarting = true; startingEpoch &+= 1; let epoch = startingEpoch
        clearScrubWindow()
        defer { if epoch == startingEpoch { isStarting = false; restoring = false } }
        restoring = true; player.pause(); restoring = false
        release()
        do {
            let result: PlaybackStart
            if fixture || !metadata.isValid {
                // Untracked sources are playable, but cannot acquire or write a
                // progress session. Debug fixture playback has the same boundary.
                result = PlaybackStart(allowed: true,lease: nil,resumePosition: nil,message: nil)
            } else {
                result = try await sync.begin(metadata: metadata,explicit: explicit,expectedSourceGeneration: expectedGeneration)
            }
            guard !disposed, epoch == startingEpoch, !Task.isCancelled else { sync.release(result.lease); return }
            guard result.allowed else {
                explicitPosition = nil; pendingGeneration = nil
                message = result.message ?? "Press Play to continue on this device"; return
            }
            lease = result.lease; localOnly = result.lease == nil
            if let captured = lease {
                invalidation = captured.$isValid.sink { [weak self, weak captured] valid in
                    guard !valid else { return }; Task { @MainActor in guard let self, self.lease === captured else { return }; self.startingEpoch &+= 1; self.startTask?.cancel(); self.isStarting = false; self.restoring = true; self.player.pause(); self.restoring = false; self.release(); self.message = "Playback continued on another device. Press Play to resume here." }
                }
            }
            let at = explicitPosition ?? result.resumePosition ?? position; explicitPosition = nil; pendingGeneration = nil
            restoring = true
            if let seekOperation { await seekOperation(player,max(0,at)) }
            else { await player.seek(to: CMTime(seconds: max(0,at),preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) }
            guard !disposed, epoch == startingEpoch, !Task.isCancelled,
                  result.lease == nil || result.lease?.isValid == true && lease === result.lease else { return }
            player.play(); message = "Playing"
        } catch { if !disposed, epoch == startingEpoch { message = error.localizedDescription } }
    }
    func save(ended: Bool = false) async { guard !disposed, !fixture, metadata.isValid, duration > 0, lease != nil || localOnly || ended else { return }; await sync.progress(metadata: metadata,lease: lease,position: position,duration: duration,ended: ended) }
    private func release() { invalidation?.cancel(); invalidation = nil; sync.release(lease); lease = nil; localOnly = false }
    func beginUserScrub() {
        guard !disposed, !closing, videoReady, player.currentItem != nil, !restoring, !isStarting,
              !handoffInProgress, player.rate == 0, player.timeControlStatus == .paused else { return }
        userScrubbing = true; positionBeforeScrub = explicitPosition
        scrubDeadline = ProcessInfo.processInfo.systemUptime + 2
    }
    func endUserScrub(cancelled: Bool) {
        guard userScrubbing else { return }
        userScrubbing = false
        if cancelled { explicitPosition = positionBeforeScrub; scrubDeadline = 0 }
        else { scrubDeadline = ProcessInfo.processInfo.systemUptime + 1 }
        positionBeforeScrub = nil
    }
    private func clearScrubWindow() { userScrubbing = false; scrubDeadline = 0; positionBeforeScrub = nil }
    /// An explicit timeline/skip action preserves a paused user's chosen point
    /// for the next fresh-generation Play. It never acquires a sync lease.
    func seek(to requested: TimeInterval) async {
        guard !Task.isCancelled, requested.isFinite, canSeek, let item = player.currentItem else { return }
        let target = min(duration,max(0,requested)), epoch = startingEpoch
        let paused = player.rate == 0 && player.timeControlStatus == .paused
        controlSeekRevision &+= 1; let revision = controlSeekRevision
        isSeeking = true
        if paused { explicitPosition = target; pendingGeneration = nil }
        defer { if controlSeekRevision == revision { isSeeking = false } }
        if let seekOperation { await seekOperation(player,target) }
        else { await player.seek(to: CMTime(seconds: target,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) }
        guard !disposed, !closing, epoch == startingEpoch, revision == controlSeekRevision,
              player.currentItem === item, !Task.isCancelled else { return }
        refreshCaption()
    }
    private func cancelControlSeek() {
        controlSeekRevision &+= 1; isSeeking = false
        player.currentItem?.cancelPendingSeeks()
    }
    private func pausedTimeJump(_ item: AnyObject?) {
        guard !disposed, !closing, let current = player.currentItem, item === current, videoReady,
              !restoring, !isStarting, !handoffInProgress, player.rate == 0,
              player.timeControlStatus == .paused,
              userScrubbing || ProcessInfo.processInfo.systemUptime <= scrubDeadline else { return }
        explicitPosition = position; pendingGeneration = nil
    }
    func background() async {
        guard !disposed, !closing else { return }
        cancelControlSeek()
        clearScrubWindow()
        let wasPlaying = player.rate > 0
        let ownedGeneration = lease.flatMap { $0.isValid ? $0.generation : nil }
        resumeOnForeground = wasPlaying && ownedGeneration != nil; pendingGeneration = ownedGeneration
        startingEpoch &+= 1; startTask?.cancel(); isStarting = false; explicitPosition = nil
        let epoch = startingEpoch, captured = lease
        restoring = true; player.pause(); restoring = false; await save()
        guard !disposed, !closing, epoch == startingEpoch, lease === captured,
              player.rate == 0 else { return }
        release()
        if wasPlaying && ownedGeneration == nil { message = "Press Play to resume on this device." }
    }
    func foreground() async {
        guard resumeOnForeground, !disposed, !closing, let generation = pendingGeneration else { return }; resumeOnForeground = false
        // The captured generation fences this automatic continuation. A device
        // that never owned a session does not enter this path.
        await play(explicit: true,expectedGeneration: generation)
    }
    func handoff() async throws -> HandoffSnapshot {
        guard !disposed, !closing, !isSeeking, !handoffInProgress else { throw CoreError.canceled }
        handoffInProgress = true
        clearScrubWindow()
        startingEpoch &+= 1; startTask?.cancel(); isStarting = false; restoring = true; player.pause(); restoring = false
        let epoch = startingEpoch, capturedLease = lease, capturedPosition = position
        message = "Saving progress before switching screens…"
        do {
            await save()
            guard !disposed, epoch == startingEpoch, !Task.isCancelled else { throw CancellationError() }
            let result = try await sync.flushForHandoff(metadata: metadata,lease: capturedLease)
            guard !disposed, epoch == startingEpoch, !Task.isCancelled else { throw CancellationError() }
            guard result.saved else { throw CoreError.message("Progress has not been saved. Reconnect Anime Sync before switching screens.") }
            return HandoffSnapshot(saved: true,position: capturedLease == nil ? result.position : capturedPosition,generation: result.generation)
        } catch {
            cancelHandoff()
            throw error
        }
    }
    /// The caller keeps the lock through TV validation/load. Failure is paused;
    /// the next actual Play acquires fresh progress without an old checkpoint.
    func cancelHandoff() {
        guard handoffInProgress else { return }
        handoffInProgress = false; startingEpoch &+= 1; startTask?.cancel(); isStarting = false
        explicitPosition = nil; pendingGeneration = nil; resumeOnForeground = false
        clearScrubWindow()
        restoring = true; player.pause(); restoring = false; release()
        if !disposed { message = "Press Play to resume on this device." }
    }
    func close() async {
        guard !disposed, !closing else { return }; closing = true; startingEpoch &+= 1; startTask?.cancel(); cueTask?.cancel(); restoring = true; player.pause(); restoring = false
        cancelControlSeek()
        clearScrubWindow()
        await save(); release(); disposed = true; handoffInProgress = false
        if let ticks { player.removeTimeObserver(ticks) }; ticks = nil
        observers.removeAll(); notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        player.replaceCurrentItem(with: nil); mediaBridge?.stop(); mediaBridge = nil
    }
    private func refreshCaption() {
        guard !disposed else { return }
        let caption = SubtitleText.active(cues,at: position - captionDelay)
        if caption != captionText { captionText = caption }
    }
    /// The owner fences provider navigation/episode identity before delivering
    /// this full candidate list. A late discovery may not undo a user's choice.
    func updateSubtitles(_ sources: [SubtitleSource]) {
        guard !disposed, !closing, !fixture else { return }
        var seen = Set<String>()
        let next = Array(sources.filter { MediaBridgePolicy.allows($0.url) && seen.insert($0.id).inserted }.prefix(32))
        if subtitles != next { subtitles = next }
        if embeddedTracksResolved || player.currentItem == nil { selectAutomaticExternal() }
    }
    private func selectAutomaticExternal() {
        let languages = embeddedOptions.map { $0.extendedLanguageTag ?? $0.locale?.identifier ?? "" }
        guard let external = NativeCaptionPolicy.automaticExternal(subtitles,embeddedLanguages: languages,automatic: automaticCaptions),
              captionSelection != external.id || activeSubtitleRequest != SubtitleRequestIdentity(external) else { return }
        loadSubtitle(external,automatic: true)
    }
    func selectSubtitle(_ source: SubtitleSource?) { loadSubtitle(source,automatic: false) }
    private func loadSubtitle(_ source: SubtitleSource?,automatic: Bool) {
        guard !disposed, !closing else { return }
        if let source, !MediaBridgePolicy.allows(source.url) {
            message = "This subtitle track needs the website player."
            return
        }
        automaticCaptions = automatic
        activeSubtitleRequest = source.map(SubtitleRequestIdentity.init)
        subtitleEpoch &+= 1; let epoch = subtitleEpoch
        cueTask?.cancel(); cues = []; captionText = ""; captionSelection = source?.id ?? "off"
        if let item = player.currentItem { Task { [weak self] in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
               let self, !self.disposed, epoch == self.subtitleEpoch, self.player.currentItem === item { item.select(nil,in: group) }
        } }
        guard let source else { return }
        cueTask = Task { [weak self] in
            do {
                var request = URLRequest(url: source.url); request.timeoutInterval = 10
                for (key,value) in MediaBridgePolicy.headers(source.headers) { request.setValue(value,forHTTPHeaderField: key) }
                guard let self else { return }
                let reply = try await self.captionTransport.request(request,maxBytes: 4_000_000)
                guard (200..<300).contains(reply.status), let text = String(data: reply.body,encoding: .utf8) else { throw CoreError.message("Subtitles could not load") }
                let parsed = SubtitleText.parse(text,extension: source.url.pathExtension)
                guard !self.disposed, !Task.isCancelled, epoch == self.subtitleEpoch, self.captionSelection == source.id else { return }
                self.cues = parsed; self.refreshCaption()
                if parsed.isEmpty { self.message = "No readable subtitles in this track. Try another track or the website player." }
            } catch { if !Task.isCancelled { self?.message = "Subtitles could not load. Try another track." } }
        }
    }
    func selectEmbedded(_ option: AVMediaSelectionOption?) {
        guard !disposed, !closing else { return }
        automaticCaptions = false
        activeSubtitleRequest = nil
        subtitleEpoch &+= 1; let epoch = subtitleEpoch
        cueTask?.cancel(); cues = []; captionText = ""; captionSelection = "embedded"
        guard let item = player.currentItem else { return }
        Task { [weak self] in if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), let self, !self.disposed, epoch == self.subtitleEpoch, self.player.currentItem === item { item.select(option,in: group) } }
    }
    func applyStyles() {
        guard let item = player.currentItem else { return }
        // The common appearance applies even to older saved "original" settings.
        // Author placement is optional; the shared face/size and clear backdrop
        // remain consistent even with an older saved original-style preference.
        var attributes: [String:Any] = [
            kCMTextMarkupAttribute_FontFamilyName as String: "Roboto",
            kCMTextMarkupAttribute_BoldStyle as String: true,
            kCMTextMarkupAttribute_RelativeFontSize as String: captionSize / 22 * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0,1.0,1.0,1.0],
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0,0.0,0.0,0.0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.0,0.0,0.0,0.0],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: kCMTextMarkupCharacterEdgeStyle_Uniform
        ]
        if !originalStyles || embeddedControlMargin > 0 {
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] = (1 - max(captionMargin,embeddedControlMargin)) * 100
        }
        item.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }
    func updateCaptionViewport(video: CGRect,controls: CGRect?) {
        guard !disposed, video.height > 0 else { return }
        var margin = 0.0
        if let controls, controls.intersects(video) {
            let lineAllowance = NativeCaptionLayout.fontSize(preference: captionSize,videoHeight: video.height) * 1.5
            margin = min(0.7,max(0,Double((video.maxY - controls.minY + lineAllowance + 12) / video.height)))
        }
        if abs(margin - embeddedControlMargin) > 0.001 { embeddedControlMargin = margin; applyStyles() }
    }
}

/// All geometry is in the host view's coordinates. Captions follow the actual
/// displayed image, never the letterbox/pillarbox or an assumed screen ratio.
enum NativeCaptionLayout {
    static func region(video: CGRect,viewport: CGRect,safeInsets: UIEdgeInsets) -> CGRect {
        guard video.minX.isFinite, video.minY.isFinite, video.width.isFinite, video.height.isFinite, video.width > 0, video.height > 0 else { return .zero }
        let result = video.intersection(viewport.inset(by: safeInsets))
        return result.isNull || result.isEmpty ? .zero : result
    }
    static func fontSize(preference: Double,videoHeight: CGFloat) -> CGFloat {
        let chosen = preference.isFinite ? preference : 22
        return min(96,max(10,videoHeight * 0.06 * CGFloat(chosen / 22)))
    }
    static func available(region: CGRect,margin: Double,controls: CGRect?,header: CGRect? = nil) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        var top = region.minY + 4
        var bottom = region.maxY - max(8,region.height * CGFloat(min(0.45,max(0.025,margin))))
        if let controls, !controls.isEmpty, controls.intersects(region) {
            bottom = min(bottom,controls.minY - 12)
        }
        if let header, !header.isEmpty, header.intersects(region) { top = max(top,header.maxY + 8) }
        guard bottom > top, region.width > 16 else { return .zero }
        return CGRect(x: region.minX + 8,y: top,width: region.width - 16,height: bottom - top)
    }
    static func fittedFontSize(preferred: CGFloat,available: CGSize,measure: (CGFloat) -> CGSize) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let text = measure(size)
            return text.width <= available.width && text.height <= available.height
        }
        if fits(preferred) { return preferred }
        var low = min(10,preferred), high = preferred
        guard fits(low) else { return low }
        for _ in 0..<8 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
    static func frame(region: CGRect,textSize: CGSize,margin: Double,controls: CGRect?,header: CGRect? = nil,padding: CGSize = CGSize(width: 4,height: 2)) -> CGRect {
        let space = available(region: region,margin: margin,controls: controls,header: header)
        guard !space.isEmpty else { return .zero }
        let width = min(max(0,textSize.width + padding.width * 2),space.width)
        let height = min(max(0,textSize.height + padding.height * 2),space.height)
        return CGRect(x: space.midX - width / 2,y: space.maxY - height,width: width,height: height)
    }
}

@MainActor enum NativeCaptionStyle {
    static let fontName = "Roboto-Bold"
    static func font(size: CGFloat) -> UIFont { UIFont(name: fontName,size: size) ?? .systemFont(ofSize: size,weight: .bold) }
    static func outlineRadius(size: CGFloat) -> CGFloat { size * 0.075 }
    static func padding(size: CGFloat) -> CGFloat { ceil(outlineRadius(size: size)) + 1 }
    static func text(_ value: String,size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: value,attributes: [.font: font(size: size),.foregroundColor: UIColor.white,.paragraphStyle: paragraph])
    }
}

/// Stroke first, then paint the opaque white glyph interior. A single thick
/// fill-and-stroke pass would thin that interior; a blur would soften the edge.
@MainActor final class NativeOutlinedCaptionLabel: UILabel {
    var outlineRadius: CGFloat = 1.5 { didSet { setNeedsDisplay() } }
    var contentPadding: CGFloat = 3 { didSet { invalidateIntrinsicContentSize(); setNeedsDisplay() } }
    private var value: NSAttributedString { attributedText ?? NativeCaptionStyle.text(text ?? "",size: font.pointSize) }
    private let options: NSStringDrawingOptions = [.usesLineFragmentOrigin,.usesFontLeading]
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = value.boundingRect(with: CGSize(width: max(1,size.width - contentPadding * 2),height: .greatestFiniteMagnitude),options: options,context: nil)
        return CGSize(width: ceil(measured.width) + contentPadding * 2,height: ceil(measured.height) + contentPadding * 2)
    }
    override func drawText(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), value.length > 0 else { return }
        let inner = rect.insetBy(dx: contentPadding,dy: contentPadding)
        guard inner.width > 0, inner.height > 0 else { return }
        let fill = NSMutableAttributedString(attributedString: value), range = NSRange(location: 0,length: value.length)
        for key in [NSAttributedString.Key.strokeWidth,.strokeColor,.shadow] { fill.removeAttribute(key,range: range) }
        fill.addAttribute(.foregroundColor,value: UIColor.white,range: range)
        let font = (fill.attribute(.font,at: 0,effectiveRange: nil) as? UIFont) ?? self.font ?? NativeCaptionStyle.font(size: 22)
        let stroke = NSMutableAttributedString(attributedString: fill)
        stroke.addAttributes([.foregroundColor: UIColor.black,.strokeColor: UIColor.black,.strokeWidth: outlineRadius * 200 / font.pointSize],range: range)
        let measured = fill.boundingRect(with: CGSize(width: inner.width,height: .greatestFiniteMagnitude),options: options,context: nil)
        let drawing = CGRect(x: inner.minX,y: inner.minY + max(0,(inner.height - ceil(measured.height)) / 2),width: inner.width,height: min(inner.height,ceil(measured.height)))
        context.saveGState(); context.clip(to: rect); context.setLineJoin(.round)
        stroke.draw(with: drawing,options: options,context: nil)
        fill.draw(with: drawing,options: options,context: nil)
        context.restoreGState()
    }
}

/// Geometry never changes the AV view's size. Coalescing a changed report after
/// UIKit layout avoids publishing during SwiftUI's update transaction; identical
/// caption/chrome layout passes do not enqueue another update.
@MainActor final class NativeVideoGeometry: ObservableObject {
    struct Snapshot: Equatable {
        var region: CGRect = .zero
        var safeViewport: CGRect = .zero
    }
    @Published private(set) var snapshot = Snapshot()
    var region: CGRect { snapshot.region }
    var safeViewport: CGRect { snapshot.safeViewport }
    private var pending: Snapshot?
    private var task: Task<Void,Never>?
    func report(_ value: CGRect,safeViewport: CGRect = .zero) {
        let next = Snapshot(region: value,safeViewport: safeViewport)
        guard next != (pending ?? snapshot) else { return }
        pending = next
        guard task == nil else { return }
        task = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            let next = self.pending ?? self.snapshot
            self.pending = nil; self.task = nil
            if self.snapshot != next { self.snapshot = next }
        }
    }
}

struct NativeChromeLayout {
    let header: CGRect
    let dock: CGRect
    static func fitted(video: CGRect,viewport: CGRect,safeInsets: UIEdgeInsets,safeViewport: CGRect? = nil,headerHeight: CGFloat = 44,dockHeight: CGFloat = 96) -> NativeChromeLayout {
        let safe = (safeViewport ?? viewport.inset(by: safeInsets)).intersection(viewport)
        guard safe.width > 0, safe.height > 0 else { return NativeChromeLayout(header: .zero,dock: .zero) }
        let clipped = video.intersection(safe)
        let content = clipped.isNull || clipped.isEmpty ? safe : clipped
        let gap: CGFloat = 8
        let imageWidth = min(safe.width,max(min(320,safe.width),content.width - gap * 2))
        let width = viewport.width > viewport.height ? min(imageWidth,340) : imageWidth
        let left = min(safe.maxX - width,max(safe.minX,content.midX - width / 2))
        let top = content.minY - safe.minY >= headerHeight + gap ? content.minY - headerHeight - gap : content.minY + gap
        let bottom = safe.maxY - content.maxY >= dockHeight + gap ? content.maxY + gap : content.maxY - dockHeight - gap
        let headerY = max(safe.minY,min(safe.maxY - headerHeight,top))
        let dockY = max(safe.minY,min(safe.maxY - dockHeight,bottom))
        return NativeChromeLayout(header: CGRect(x: left,y: headerY,width: width,height: headerHeight),
                                  dock: CGRect(x: left,y: dockY,width: width,height: dockHeight))
    }
}

enum NativeSafeArea {
    /// windowSafe is converted by the owning host from its own window. This
    /// preserves notches/Home insets even when SwiftUI ignores safe areas.
    static func viewport(bounds: CGRect,localInsets: UIEdgeInsets,windowSafe: CGRect) -> CGRect {
        let result = bounds.inset(by: localInsets).intersection(windowSafe).intersection(bounds)
        return result.isNull || result.isEmpty ? .zero : result
    }
}

/// AVPlayerViewController is contained, not subclassed. Its public videoBounds
/// supplies the image rectangle; a single app-owned chrome avoids competing
/// native close/volume/transport overlays with independent hide timers.
@MainActor final class NativeVideoHostController: UIViewController {
    let playback = AVPlayerViewController()
    let caption = NativeOutlinedCaptionLabel()
    var captionText = ""
    var captionSize: Double = 22
    var captionMargin: Double = 0.1
    var controlsFrame: CGRect?
    var headerFrame: CGRect?
    weak var model: NativePlaybackModel?
    weak var geometry: NativeVideoGeometry?
    #if DEBUG
    private let qaVideoRegion = UIView()
    #endif
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playback.showsPlaybackControls = false
        playback.allowsVideoFrameAnalysis = false
        playback.allowsPictureInPicturePlayback = false
        addChild(playback); view.addSubview(playback.view)
        playback.view.frame = view.bounds; playback.view.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        playback.didMove(toParent: self)
        caption.numberOfLines = 0; caption.textAlignment = .center
        caption.backgroundColor = .clear; caption.isUserInteractionEnabled = false; caption.clipsToBounds = true
        caption.isAccessibilityElement = true; caption.accessibilityIdentifier = "player.caption"
        #if DEBUG
        qaVideoRegion.isUserInteractionEnabled = false; qaVideoRegion.backgroundColor = .clear
        qaVideoRegion.isAccessibilityElement = true; qaVideoRegion.accessibilityIdentifier = "qa.player.video-region"
        qaVideoRegion.accessibilityLabel = "Video image"; qaVideoRegion.alpha = 0.01
        qaVideoRegion.isHidden = model?.fixture != true
        view.addSubview(qaVideoRegion)
        #endif
        view.addSubview(caption)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutCaption() }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); view.setNeedsLayout() }
    override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); view.setNeedsLayout() }
    func layoutCaption() {
        guard isViewLoaded else { return }
        guard let window = view.window else { caption.isHidden = true; return }
        let windowSafe = view.convert(window.bounds.inset(by: window.safeAreaInsets),from: window)
        let safe = NativeSafeArea.viewport(bounds: view.bounds,localInsets: view.safeAreaInsets,windowSafe: windowSafe)
        let video = playback.view.convert(playback.videoBounds,to: view)
        let clipped = video.intersection(safe)
        let region = clipped.isNull || clipped.isEmpty ? CGRect.zero : clipped
        geometry?.report(region,safeViewport: safe)
        #if DEBUG
        qaVideoRegion.frame = region
        #endif
        model?.updateCaptionViewport(video: video,controls: controlsFrame)
        guard !captionText.isEmpty, region.width > 0, region.height > 0 else { caption.isHidden = true; return }
        let space = NativeCaptionLayout.available(region: region,margin: captionMargin,controls: controlsFrame,header: headerFrame)
        guard space.width > 8, space.height > 4 else { caption.isHidden = true; return }
        let preferred = NativeCaptionLayout.fontSize(preference: captionSize,videoHeight: video.height)
        caption.contentPadding = NativeCaptionStyle.padding(size: preferred)
        func measure(_ size: CGFloat) -> CGSize {
            caption.attributedText = NativeCaptionStyle.text(captionText,size: size)
            return caption.sizeThatFits(CGSize(width: space.width,height: .greatestFiniteMagnitude))
        }
        let fitted = NativeCaptionLayout.fittedFontSize(preferred: preferred,available: space.size,measure: measure)
        caption.outlineRadius = NativeCaptionStyle.outlineRadius(size: fitted)
        let size = measure(fitted)
        caption.frame = NativeCaptionLayout.frame(region: region,textSize: size,margin: captionMargin,controls: controlsFrame,header: headerFrame,padding: .zero)
        caption.isHidden = false
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    @ObservedObject var model: NativePlaybackModel
    var onVideoTap: () -> Void = {}
    var controlsFrame: CGRect? = nil
    var headerFrame: CGRect? = nil
    var geometry: NativeVideoGeometry? = nil
    func makeUIViewController(context: Context) -> NativeVideoHostController {
        let host = NativeVideoHostController(); host.model = model; host.geometry = geometry; host.loadViewIfNeeded(); host.playback.player = model.player
        context.coordinator.observation = host.playback.observe(\.isReadyForDisplay,options: [.new]) { [weak model,weak host] vc, _ in
            Task { @MainActor in model?.videoReady = vc.isReadyForDisplay; host?.view.setNeedsLayout() }
        }
        context.coordinator.boundsObservation = host.playback.observe(\.videoBounds,options: [.new]) { [weak host] _,_ in
            Task { @MainActor in host?.view.setNeedsLayout() }
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.swipe(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator; host.view.addGestureRecognizer(pan)
        host.view.addGestureRecognizer(context.coordinator.videoTapRecognizer())
        return host
    }
    func updateUIViewController(_ host: NativeVideoHostController, context: Context) {
        context.coordinator.onVideoTap = onVideoTap
        host.captionText = model.captionText; host.captionSize = model.captionSize
        host.captionMargin = model.captionMargin; host.controlsFrame = controlsFrame; host.headerFrame = headerFrame
        host.geometry = geometry
        host.layoutCaption()
    }
    func makeCoordinator() -> Coordinator { Coordinator(model,onVideoTap: onVideoTap) }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: NativePlaybackModel
        var observation: NSKeyValueObservation?
        var boundsObservation: NSKeyValueObservation?
        var onVideoTap: () -> Void
        init(_ model: NativePlaybackModel,onVideoTap: @escaping () -> Void) { self.model = model; self.onVideoTap = onVideoTap; super.init() }
        func videoTapRecognizer() -> UITapGestureRecognizer {
            let tap = UITapGestureRecognizer(target: self,action: #selector(videoTapped(_:)))
            tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false; tap.delegate = self
            return tap
        }
        @objc func videoTapped(_ gesture: UITapGestureRecognizer) { if gesture.state == .ended { onVideoTap() } }
        @objc func swipe(_ gesture: UIPanGestureRecognizer) { if gesture.state == .ended { let p = gesture.translation(in: gesture.view); if p.x > 96 && abs(p.y) < p.x * 0.5 { model.onClose?() } } }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { if gestureRecognizer is UITapGestureRecognizer { return true }; guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }; let v = pan.velocity(in: pan.view); return v.x > abs(v.y) * 1.5 }
        static func acceptsVideoTouch(_ original: UIView?) -> Bool { var current = original; while let v = current { if v is UIControl || v is UIScrollView || String(describing: type(of: v)).localizedCaseInsensitiveContains("scrub") { return false }; current = v.superview }; return true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldReceive touch: UITouch) -> Bool { Self.acceptsVideoTouch(touch.view) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

private struct PlaybackControlsFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect,nextValue: () -> CGRect) { value = nextValue() }
}

#if DEBUG
private struct QAPauseButtonFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect,nextValue: () -> CGRect) {
        let frame = nextValue()
        if !frame.isEmpty { value = frame }
    }
}
#endif

@MainActor private struct NativeTransportBar: View {
    @ObservedObject var model: NativePlaybackModel
    let playing: Bool
    let width: CGFloat
    let compact: Bool
    var onInteraction: () -> Void
    var onScrubbing: (Bool) -> Void
    @State private var draft: Double?
    @State private var editing = false
    @State private var seekTask: Task<Void,Never>?
    @State private var pendingSeek: Double?
    private var sidePadding: CGFloat { compact ? 10 : 14 }
    var body: some View {
        // Paused playback has no changing clock. Draft edits and the observed
        // seek/start model still refresh the dock after an explicit action.
        TimelineView(.animation(minimumInterval: 0.5,paused: !playing)) { _ in transport }
            .padding(.horizontal,sidePadding)
            .padding(.vertical,compact ? 3 : 8)
            .frame(width: width)
            .background(.black.opacity(compact ? 0.5 : 0.65),in: RoundedRectangle(cornerRadius: compact ? 14 : 18))
            .onDisappear { seekTask?.cancel(); pendingSeek = nil; onScrubbing(false) }
    }
    private var transport: some View {
        let sliderScale: CGFloat = compact ? 0.75 : 1
        let sliderWidth = max(1,width - sidePadding * 2)
        return VStack(spacing: compact ? 0 : 4) {
            HStack(spacing: compact ? 6 : 20) {
                Button { skip(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: compact ? 15 : 18))
                        .frame(width: 44,height: 44)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Back ten seconds").accessibilityIdentifier("player.skip.back")
                    .disabled(!model.canSeek)
                Button {
                    onInteraction()
                    if model.player.rate > 0 { model.player.pause() }
                    else { Task { await model.play(explicit: true) } }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(compact ? .system(size: 17,weight: .semibold) : .title2)
                        .frame(width: 44,height: 44)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel(playing ? "Pause" : "Play").accessibilityIdentifier("player.play-pause")
                    .disabled(model.isStarting || model.isSeeking || model.handoffInProgress)
                    #if DEBUG
                    .background {
                        if model.fixture {
                            GeometryReader { geometry in
                                Color.clear.preference(key: QAPauseButtonFrameKey.self,value: geometry.frame(in: .global))
                            }.allowsHitTesting(false)
                        }
                    }
                    #endif
                Button { skip(10) } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: compact ? 15 : 18))
                        .frame(width: 44,height: 44)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Forward ten seconds").accessibilityIdentifier("player.skip.forward")
                    .disabled(!model.canSeek)
            }.frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if model.isStarting || model.isSeeking { ProgressView().controlSize(.small).frame(width: 24,height: 44) }
                }
            Slider(value: Binding(get: { min(max(0,draft ?? model.position),max(1,model.duration)) },set: { value in
                draft = value
                // Accessibility adjustments need not start a touch drag.
                if !editing { commit(value) }
            }),in: 0...max(1,model.duration),onEditingChanged: { value in
                editing = value; onScrubbing(value); onInteraction()
                if value { draft = model.position }
                else if let draft { commit(draft) }
            }).tint(.white).disabled(!model.canSeek && !editing)
                // Scale the native thumb and track together. Compensate for
                // horizontal scaling so the rail keeps its full seek range.
                .frame(width: sliderWidth / sliderScale)
                .scaleEffect(sliderScale)
                .frame(width: sliderWidth,height: compact ? 26 : nil)
                .accessibilityLabel("Episode timeline").accessibilityIdentifier("player.timeline")
            Text(Self.time(draft ?? model.position) + " / " + Self.time(model.duration))
                .font((compact ? Font.system(size: 10) : .caption).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity,alignment: .leading)
                .accessibilityLabel("Playback position").accessibilityIdentifier("player.time")
        }.buttonStyle(.plain).foregroundStyle(.white)
    }
    private func skip(_ delta: Double) { onInteraction(); commit(model.position + delta) }
    private func commit(_ target: Double) {
        guard seekTask != nil || !model.isSeeking else { draft = nil; return }
        pendingSeek = target
        guard seekTask == nil else { return }
        seekTask = Task {
            while let target = pendingSeek, !Task.isCancelled {
                pendingSeek = nil
                await model.seek(to: target)
            }
            draft = nil; seekTask = nil; onInteraction()
        }
    }
    private static func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0,min(value,359999))) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d",seconds / 3600,(seconds / 60) % 60,seconds % 60) }
        return String(format: "%d:%02d",seconds / 60,seconds % 60)
    }
}

@MainActor struct NativePlayerScreen: View {
    @ObservedObject var model: NativePlaybackModel
    @StateObject private var toolbar = PlaybackToolbarState()
    @StateObject private var videoGeometry = NativeVideoGeometry()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var captions = false
    @State private var options = false
    @State private var appeared = false
    @State private var scrubbing = false
    @State private var playing = false
    @State private var transportHeight: CGFloat = 96
    #if DEBUG
    @State private var qaPauseFrame: CGRect = .zero
    #endif
    var onTV: () -> Void
    var tvPanelPresented: Bool = false
    var body: some View {
        GeometryReader { geometry in player(in: geometry) }
            .ignoresSafeArea()
            .statusBarHidden(true)
            .animation(.easeInOut(duration: 0.2),value: toolbar.visible)
            .task { await model.prepare() }
            .sheet(isPresented: $captions) { SubtitleSettings(model: model) }
            .confirmationDialog("Playback options",isPresented: $options,titleVisibility: .visible) {
                Button(model.player.isMuted ? "Unmute" : "Mute") { model.player.isMuted.toggle(); toolbar.reveal() }
                Button("Use website player") { model.onFallback?() }
                Button("Cancel",role: .cancel) { }
            }
            .onAppear { appeared = true; playing = model.player.rate > 0; updateToolbar() }
            .onDisappear { appeared = false; toolbar.stop() }
            .onReceive(model.player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) {
                playing = $0 != .paused
                updateToolbar(playing: $0 == .playing)
            }
            .onChange(of: captions) { _,_ in updateToolbar() }
            .onChange(of: options) { _,_ in updateToolbar() }
            .onChange(of: tvPanelPresented) { _,_ in updateToolbar() }
            .onChange(of: model.isSeeking) { _,_ in updateToolbar() }
            .onChange(of: model.isStarting) { _,_ in updateToolbar() }
            .onChange(of: voiceOver) { _,_ in updateToolbar() }
            .onChange(of: scenePhase) { _,_ in updateToolbar() }
    }
    private func player(in geometry: GeometryProxy) -> some View {
        let layout = chromeLayout(in: geometry)
        return ZStack {
            Color.black
            NativePlayerController(model: model,onVideoTap: { toolbar.reveal() },controlsFrame: toolbar.visible ? layout.dock : nil,
                                   headerFrame: toolbar.visible ? layout.header : nil,geometry: videoGeometry)
            if toolbar.visible, !videoGeometry.safeViewport.isEmpty {
                chrome(layout: layout,compact: geometry.size.width > geometry.size.height).transition(.opacity)
            }
            if model.message != "Playing" {
                VStack { Spacer(); Text(model.message).font(.footnote).multilineTextAlignment(.center)
                    .padding(10).background(.black.opacity(0.7),in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal,20).padding(.bottom,geometry.safeAreaInsets.bottom + 130)
                }.allowsHitTesting(false)
            }
            #if DEBUG
            if model.fixture {
                Text(model.videoReady ? "Ready" : "Waiting").font(.caption2).opacity(0.01).accessibilityIdentifier("qa.player.ready").accessibilityValue(model.videoReady ? "ready" : "waiting").allowsHitTesting(false)
                Text("Playback position").font(.caption2).opacity(0.01).accessibilityIdentifier("qa.player.time").accessibilityValue(String(model.qaPosition)).allowsHitTesting(false)
                Text(toolbar.visible ? "Controls visible" : "Controls hidden").font(.caption2).opacity(0.01).accessibilityIdentifier("qa.player.controls").allowsHitTesting(false)
                if !qaPauseFrame.isEmpty {
                    // Preserve the last rendered button position through auto-hide,
                    // so UI tests can perform two real taps without an AX lookup in between.
                    Text("Play or pause hit point").font(.caption2).opacity(0.01)
                        .accessibilityIdentifier("qa.player.pause-point")
                        .accessibilityValue(Text(verbatim: "\(qaPauseFrame.midX),\(qaPauseFrame.midY)"))
                        .allowsHitTesting(false)
                }
            }
            #endif
        }.coordinateSpace(name: "native.player")
            .onPreferenceChange(PlaybackControlsFrameKey.self) {
                if $0.height > 0, abs(transportHeight - $0.height) > 0.5 { transportHeight = $0.height }
            }
            #if DEBUG
            .onPreferenceChange(QAPauseButtonFrameKey.self) { frame in
                if !frame.isEmpty, frame != qaPauseFrame { qaPauseFrame = frame }
            }
            #endif
    }
    private func chromeLayout(in geometry: GeometryProxy) -> NativeChromeLayout {
        let insets = geometry.safeAreaInsets
        return NativeChromeLayout.fitted(video: videoGeometry.region,viewport: CGRect(origin: .zero,size: geometry.size),
                                         safeInsets: UIEdgeInsets(top: insets.top,left: insets.leading,bottom: insets.bottom,right: insets.trailing),
                                         safeViewport: videoGeometry.safeViewport.isEmpty ? nil : videoGeometry.safeViewport,
                                         dockHeight: transportHeight)
    }
    private func chrome(layout: NativeChromeLayout,compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            controls(compact: compact).frame(width: layout.header.width,height: layout.header.height)
                .position(x: layout.header.midX,y: layout.header.midY)
            NativeTransportBar(model: model,playing: playing,width: layout.dock.width,compact: compact,onInteraction: { toolbar.reveal() },onScrubbing: {
                scrubbing = $0; updateToolbar()
            }).background(GeometryReader { proxy in
                Color.clear.preference(key: PlaybackControlsFrameKey.self,value: proxy.frame(in: .named("native.player")))
            }).accessibilityElement(children: .contain).accessibilityIdentifier("player.transport")
                .position(x: layout.dock.midX,y: layout.dock.midY)
        }
    }
    private func controls(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 8) {
            Button { model.onClose?() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back").accessibilityIdentifier("player.close")
            Text(model.metadata.title)
                .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { toolbar.reveal(); captions = true } label: { Image(systemName: "captions.bubble") }
                .accessibilityLabel("Subtitles").accessibilityIdentifier("player.subtitles")
            Button { toolbar.reveal(); onTV() } label: {
                Image("tv-connect").resizable().renderingMode(.template).scaledToFit()
                    .frame(width: compact ? 16 : 20,height: compact ? 16 : 20)
            }
                .accessibilityLabel("Play on TV").disabled(model.isSeeking || model.handoffInProgress)
            Button { toolbar.reveal(); options = true } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Playback options").accessibilityIdentifier("player.options")
        }.buttonStyle(PlaybackIconButtonStyle(compact: compact)).foregroundStyle(.white)
            .padding(.horizontal,4)
            .background { Capsule().fill(.black.opacity(0.45)).frame(height: compact ? 32 : 44) }
            .accessibilityIdentifier("player.toolbar")
    }
    private func updateToolbar(playing: Bool? = nil) {
        toolbar.update(playing: playing ?? (model.player.timeControlStatus == .playing),active: appeared && scenePhase == .active,
                       presenting: captions || options || tvPanelPresented || scrubbing || model.isSeeking || model.isStarting,voiceOver: voiceOver)
    }
}

private struct PlaybackIconButtonStyle: ButtonStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 15 : 18,weight: .semibold))
            .frame(width: 44,height: 44)
            .contentShape(Rectangle())
            .background { Circle().fill(.white.opacity(configuration.isPressed ? 0.15 : 0)).frame(width: compact ? 32 : 44) }
    }
}
struct SubtitleSettings: View {
    @ObservedObject var model: NativePlaybackModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Tracks") {
                    Button("Off") { model.selectSubtitle(nil) }.accessibilityIdentifier("player.subtitle.off")
                    ForEach(Array(model.embeddedOptions.enumerated()),id: \.offset) { _,option in Button(option.displayName) { model.selectEmbedded(option) } }
                    ForEach(Array(model.subtitles.enumerated()),id: \.offset) { index,source in
                        Button(source.label) { model.selectSubtitle(source) }.accessibilityIdentifier("player.subtitle.track.\(index)")
                    }
                    if model.embeddedOptions.isEmpty && model.subtitles.isEmpty { Text("No selectable subtitles found for this source.") }
                }
                Section("Appearance") {
                    Stepper("Size \(Int(model.captionSize))",value: $model.captionSize,in: 14...44,step: 2)
                    Button("Larger subtitles") { model.captionSize = min(44,model.captionSize + 2) }.accessibilityIdentifier("player.subtitle.larger")
                    Button("Raise subtitles") { model.captionMargin = min(0.45,model.captionMargin + 0.025) }.accessibilityIdentifier("player.subtitle.raise")
                    Button("Lower subtitles") { model.captionMargin = max(0.025,model.captionMargin - 0.025) }
                    Toggle("Original embedded placement",isOn: $model.originalStyles).accessibilityIdentifier("player.subtitle.style")
                    Slider(value: $model.captionDelay,in: -10...10,step: 0.5)
                    Text(String(format: "Subtitle timing: %+.1f s",model.captionDelay)).font(.footnote)
                    if model.subtitles.contains(where: { ["ass","ssa"].contains($0.url.pathExtension.lowercased()) }) { Text("ASS tracks use plain text here; complex typesetting may look different. Baked-in subtitles cannot be changed.").font(.footnote) }
                }
            }.accessibilityIdentifier("player.subtitle.settings").navigationTitle("Subtitles").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("player.subtitle.done") } }
        }.preferredColorScheme(.dark)
    }
}

#if DEBUG
private struct QACaptionTransport: HTTPTransport {
    static let url = URL(string: "https://example.invalid/qa-caption.vtt")!
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply {
        guard request.url == Self.url else { throw CoreError.invalidResponse }
        let body = Data("WEBVTT\n\n00:00:00.000 --> 00:10:00.000\nQA external VTT caption\n\n".utf8)
        guard body.count <= maxBytes else { throw CoreError.responseTooLarge }
        return HTTPReply(status: 200,body: body)
    }
}
#endif
