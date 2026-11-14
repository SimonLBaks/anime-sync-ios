import SwiftUI
import AVKit
import Combine
import CoreMedia

/// Auto-hides while video is playing and also accepts an explicit video tap.
/// A revision fences an old timer even when its sleeper ignores cancellation.
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
        if changed { reveal() }
    }
    func toggleFromVideoTap(hideAfter delay: UInt64? = nil) {
        guard canToggle else { return }
        if visible {
            cancel(); visible = false
        } else {
            reveal(hideAfter: delay)
        }
    }
    func reveal(hideAfter delay: UInt64? = nil) {
        visible = true; cancel()
        guard canAutoHide else { return }
        let captured = revision, sleep = sleep
        hideTask = Task { [weak self] in
            do {
                try await sleep(delay ?? 4_000_000_000)
                guard !Task.isCancelled, let self, self.revision == captured, self.canAutoHide else { return }
                self.visible = false; self.hideTask = nil
            } catch { }
        }
    }
    func stop() { active = false; cancel(); visible = true }
    private var canToggle: Bool { active && !presenting && !voiceOver }
    private var canAutoHide: Bool { playing && canToggle }
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

private final class EmbeddedCaptionOutput: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    // AVFoundation invokes this delegate on the main queue supplied below.
    let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
    private let receive: @MainActor ([String]) -> Void

    init(receive: @escaping @MainActor ([String]) -> Void) {
        self.receive = receive
        super.init()
        output.setDelegate(self,queue: .main)
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput,didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any],forItemTime itemTime: CMTime) {
        MainActor.assumeIsolated { receive(strings.map(\.string)) }
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated { receive([]) }
    }
}

/// AVPlayer's seek completion can remain pending after a failed item or an
/// interrupted connection. Bound the UI gate independently of that callback.
@MainActor private final class PlaybackStartupSeek {
    private var continuation: CheckedContinuation<Bool,Never>?
    private var result: Bool?
    private var work: Task<Void,Never>?
    private var deadline: Task<Void,Never>?
    private let cancelSeek: () -> Void
    init(cancelSeek: @escaping () -> Void) { self.cancelSeek = cancelSeek }
    func wait(timeout: TimeInterval,operation: @escaping @MainActor () async -> Bool) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result { continuation.resume(returning: result); return }
                self.continuation = continuation
                work = Task { [weak self] in
                    let completed = await operation()
                    guard !Task.isCancelled else { return }
                    self?.finish(completed)
                }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01,min(60,timeout)) * 1_000_000_000)) }
                    catch { return }
                    self?.finish(false)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(false) } }
    }
    func finish(_ completed: Bool) {
        guard result == nil else { return }; result = completed
        let continuation = continuation; self.continuation = nil
        deadline?.cancel(); deadline = nil; work?.cancel(); work = nil
        if !completed { cancelSeek() }
        continuation?.resume(returning: completed)
    }
}

@MainActor final class NativePlaybackModel: ObservableObject, Identifiable {
    let id = UUID()
    let metadata: AnimeMetadata
    private(set) var source: MediaSource
    var refreshSource: ((MediaSource) async throws -> (source: MediaSource, subtitles: [SubtitleSource]))?
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
    @Published var captionMargin: Double { didSet { if !fixture { UserDefaults.standard.set(captionMargin,forKey: "caption.edgeMargin") } } }
    @Published var originalStyles: Bool { didSet { if !fixture { UserDefaults.standard.set(originalStyles,forKey: "caption.sourcePlacement") }; applyStyles(); refreshCaption() } }
    @Published var captionDelay: Double = 0 { didSet { refreshCaption() } }
    @Published var captionSelection = "automatic"
    @Published var embeddedOptions: [AVMediaSelectionOption] = []
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var selectedAudio: AVMediaSelectionOption?
    @Published private(set) var playbackSpeed: Float = 1
    private var audioGroup: AVMediaSelectionGroup?
    static let playbackSpeeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]
    @Published var isStarting = false
    @Published private(set) var wantsPlayback = false
    @Published private(set) var isSeeking = false
    @Published private(set) var handoffInProgress = false
    @Published private(set) var activeSegment: PlaybackSegment?
    @Published var nextEpisode: EpisodeChoice?
    @Published var nextEpisodePrompt: EpisodeChoice?
    @Published private(set) var reachedEnd = false
    private var segments: [PlaybackSegment]
    private(set) var finishedGeneration: Int64?
    var resolveNextEpisode: (([EpisodeChoice]) -> EpisodeChoice?)?
    private var lastPlaybackGeneration: Int64?
    var onNextEpisode: ((EpisodeChoice,Int64?) -> Void)?
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
    private var emptySubtitleRequests: [SubtitleRequestIdentity] = []
    private var startTask: Task<Void,Never>?
    private var claimTask: Task<PlaybackStart,Error>?
    private var sourceRefreshTask: Task<(source: MediaSource, subtitles: [SubtitleSource]),Error>?
    private var pauseSave: (epoch: UInt64, task: Task<Void,Never>)?
    private var pendingGeneration: Int64?
    private var explicitPosition: TimeInterval?
    private var reconnectCheckpoint: (account: UInt64, position: TimeInterval)?
    private var previousLease: PlaybackLease?
    private var lastClockSample: (position: TimeInterval, duration: TimeInterval)?
    private var clockTarget: TimeInterval?
    private let clock: (() -> (position: TimeInterval, duration: TimeInterval))?
    private let seekOperation: ((AVPlayer, TimeInterval) async -> Void)?
    private var resumeOnForeground = false
    private var backgrounded = false
    private var itemNeedsReload = false
    private var itemStatusObservation: NSKeyValueObservation?
    private var startupSeek: PlaybackStartupSeek?
    private let startupSeekTimeout: TimeInterval
    private let itemFactory: ((MediaSource) async throws -> AVPlayerItem)?
    private var startingEpoch: UInt64 = 0
    private var restoring = false
    private var disposed = false
    private var closing = false
    private var localOnly = false
    private var checkpointReady = false
    private var knownCheckpointAccount: UInt64?
    private var userScrubbing = false
    private var scrubDeadline: TimeInterval = 0
    private var positionBeforeScrub: TimeInterval?
    private var controlSeekRevision: UInt64 = 0
    private var embeddedOutput: EmbeddedCaptionOutput?
    private var embeddedCaption = ""
    private var cues: [SubtitleCue] = []
    private var periodicCount = 0
    var onFallback: (() -> Void)?
    var onClose: (() -> Void)?
    var position: TimeInterval { let x = clock?().position ?? player.currentTime().seconds; return x.isFinite ? max(0,x) : 0 }
    var duration: TimeInterval { let x = clock?().duration ?? player.currentItem?.duration.seconds ?? 0; return x.isFinite ? max(0,x) : 0 }
    var captionsEnabled: Bool { captionSelection != "off" && (!subtitles.isEmpty || !embeddedOptions.isEmpty) }
    var showingExternalCaption: Bool { !cues.isEmpty }
    var canSeek: Bool { !disposed && !closing && !itemNeedsReload && videoReady && player.currentItem != nil && duration > 0 && !restoring && !isStarting && !handoffInProgress && !isSeeking }

    init(metadata: AnimeMetadata, source: MediaSource, subtitles: [SubtitleSource], sync: SyncService, fixture: Bool = false, position: TimeInterval? = nil, generation: Int64? = nil, clock: (() -> (position: TimeInterval, duration: TimeInterval))? = nil, captionTransport: HTTPTransport? = nil, seekOperation: ((AVPlayer, TimeInterval) async -> Void)? = nil, startupSeekTimeout: TimeInterval = 12, itemFactory: ((MediaSource) async throws -> AVPlayerItem)? = nil) {
        self.metadata = metadata; self.source = source; self.sync = sync; self.fixture = fixture
        segments = source.segments
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
        self.explicitPosition = position; self.pendingGeneration = generation; self.clock = clock; self.seekOperation = seekOperation; self.startupSeekTimeout = startupSeekTimeout; self.itemFactory = itemFactory
        knownCheckpointAccount = sync.isSignedIn && (generation != nil || (position ?? 0) > 0) ? sync.accountGeneration : nil
        captionSize = fixture ? 22 : UserDefaults.standard.object(forKey: "caption.size") as? Double ?? 22
        let savedMargin = UserDefaults.standard.object(forKey: "caption.edgeMargin") as? Double
        captionMargin = fixture ? NativeCaptionLayout.defaultMargin : NativeCaptionLayout.margin(savedMargin ?? NativeCaptionLayout.defaultMargin)
        originalStyles = !fixture && UserDefaults.standard.bool(forKey: "caption.sourcePlacement")
        player.isMuted = fixture; player.allowsExternalPlayback = false
        observers.append(player.observe(\.rate, options: [.new]) { [weak self] _, change in Task { @MainActor in self?.rateChanged(change.newValue ?? 0) } })
        ticks = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25,preferredTimescale: 600),queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.disposed else { return }
                if !self.isStarting, !self.isSeeking { _ = self.confirmClockSample() }
                self.refreshCaption(); self.refreshSegment()
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
            guard let self, !self.disposed, !self.closing, self.checkpointReady, note.object as AnyObject? === self.player.currentItem else { return }
            let epoch = self.startingEpoch, item = self.player.currentItem, captured = self.lease
            let canContinue = captured?.isValid == true || self.localOnly
            guard let sample = self.confirmClockSample(), sample.position >= sample.duration - 2 else {
                if let current = self.player.currentItem { self.playbackFailed(current) }
                return
            }
            await self.save(ended: true)
            guard !self.disposed, !self.closing, self.startingEpoch == epoch,
                  self.player.currentItem === item, self.lease === captured, self.player.rate == 0 else { return }
            self.finishedGeneration = captured?.isValid == true ? captured?.generation : nil
            self.reachedEnd = true
            self.wantsPlayback = false
            self.release(); self.refreshSegment(); self.message = "Episode finished"
            if canContinue, captured?.isValid != false { self.nextEpisodePrompt = self.nextEpisode }
        } })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,object: nil,queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.playbackFailed(note.object as? AVPlayerItem) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,object: nil,queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in await self?.background() }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped,object: nil,queue: .main) { [weak self] note in
            // The main-queue notification is handled inline: deferring to a Task
            // could observe restoring=false after our own programmatic seek.
            MainActor.assumeIsolated { self?.pausedTimeJump(note.object as AnyObject?) }
        })
    }
    func prepare() async {
        guard !disposed, !closing, player.currentItem == nil else { return }
        await play(explicit: true,expectedGeneration: pendingGeneration)
    }
    private func replacePlaybackItem(epoch: UInt64) async throws {
        let nextBridge: MediaBridge?
        let item: AVPlayerItem
        if let itemFactory { nextBridge = nil; item = try await itemFactory(source) }
        else {
            let bridge = try await MediaBridge(source: source)
            nextBridge = bridge; item = AVPlayerItem(url: bridge.url)
        }
        guard !disposed, !closing, epoch == startingEpoch, !Task.isCancelled else { nextBridge?.stop(); throw CancellationError() }
        itemStatusObservation?.invalidate()
        if let embeddedOutput { player.currentItem?.remove(embeddedOutput.output) }
        mediaBridge?.stop(); mediaBridge = nextBridge
        let audioName = selectedAudio?.displayName
        videoReady = false; embeddedOptions = []; audioOptions = []; selectedAudio = nil; audioGroup = nil
        embeddedTracksResolved = false; embeddedCaption = ""; itemNeedsReload = false
        itemStatusObservation = item.observe(\.status,options: [.new]) { [weak self] item, _ in Task { @MainActor in
            if item.status == .failed { self?.playbackFailed(item) }
        } }
        installEmbeddedCaptionOutput(on: item)
        player.replaceCurrentItem(with: item); applyStyles()
        Task { [weak self] in await self?.readEmbeddedTracks(item) }
        Task { [weak self] in await self?.readAudioTracks(item,preferredName: audioName) }
    }
    private func playbackFailed(_ item: AVPlayerItem?) {
        guard !disposed, !closing, !itemNeedsReload, let item, player.currentItem === item else { return }
        if let sample = saveSample(),
           sync.enqueueProgress(metadata: metadata,lease: lease,position: sample.position,duration: sample.duration) {
            Task { [sync] in await sync.flushPending() }
        }
        itemNeedsReload = true; videoReady = false
        startingEpoch &+= 1; cancelPendingStart(); isStarting = false
        cancelControlSeek()
        wantsPlayback = false; resumeOnForeground = false; pendingGeneration = nil; explicitPosition = nil
        restoring = true; player.pause(); restoring = false; release()
        message = "The connection to this source stopped. Press Play to retry, or choose another source."
    }
    private func cancelPendingStart() {
        startTask?.cancel(); startTask = nil
        claimTask?.cancel(); claimTask = nil
        sourceRefreshTask?.cancel(); sourceRefreshTask = nil
        startupSeek?.finish(false); startupSeek = nil
    }
    private func seekForStart(to position: TimeInterval) async -> Bool {
        let item = self.player.currentItem, player = self.player, operation = seekOperation
        let request = PlaybackStartupSeek(cancelSeek: { item?.cancelPendingSeeks() })
        startupSeek?.finish(false); startupSeek = request
        let completed = await request.wait(timeout: startupSeekTimeout) {
            if let operation { await operation(player,position); return !Task.isCancelled }
            return await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: position,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
        }
        if startupSeek === request { startupSeek = nil }
        return completed
    }
    private func readAudioTracks(_ item: AVPlayerItem,preferredName: String?) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              !disposed, !closing, player.currentItem === item else { return }
        audioGroup = group
        audioOptions = group.options
        if let preferredName, let option = group.options.first(where: { $0.displayName == preferredName }) { selectAudio(option) }
    }
    func selectAudio(_ option: AVMediaSelectionOption?) {
        guard !disposed, !closing, let item = player.currentItem, let group = audioGroup else { return }
        if let option { item.select(option,in: group) }
        else { item.selectMediaOptionAutomatically(in: group) }
        selectedAudio = option
    }
    func setPlaybackSpeed(_ speed: Float) {
        guard !disposed, !closing, Self.playbackSpeeds.contains(speed) else { return }
        playbackSpeed = speed
        player.defaultRate = speed
        if player.rate > 0 { player.rate = speed }
    }
    func installEmbeddedCaptionOutput(on item: AVPlayerItem) {
        let adapter = EmbeddedCaptionOutput { [weak self,weak item] strings in
            guard let self, let item, self.player.currentItem === item, !self.disposed, !self.closing else { return }
            self.embeddedCaption = SubtitleText.dialogue(strings)
            self.refreshCaption()
        }
        adapter.output.suppressesPlayerRendering = !originalStyles
        embeddedOutput = adapter
        item.add(adapter.output)
    }
    private func readEmbeddedTracks(_ item: AVPlayerItem) async {
        do {
            let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !disposed, !closing, player.currentItem === item else { return }
            embeddedOptions = group?.options ?? []
            embeddedTracksResolved = true
            guard automaticCaptions else {
                if let group {
                    let selected = group.options.first { "embedded:" + $0.displayName == captionSelection }
                    item.select(selected,in: group)
                }
                return
            }
            if let group, let english = group.options.first(where: { NativeCaptionPolicy.isEnglish($0.extendedLanguageTag ?? $0.locale?.identifier ?? "") }) {
                subtitleEpoch &+= 1; cueTask?.cancel(); cues = []; embeddedCaption = ""; captionText = ""; captionSelection = "automatic"; activeSubtitleRequest = nil
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
        } else if rate > 0, !backgrounded {
            wantsPlayback = true
        }
    }
    func pause() {
        guard !disposed, !closing, !isStarting, !backgrounded else { return }
        wantsPlayback = false
        player.pause()
        let epoch = startingEpoch, captured = lease
        guard checkpointReady, pauseSave?.epoch != epoch else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            guard self.startingEpoch == epoch || self.backgrounded && self.lease === captured else { return }
            await self.save()
            if self.pauseSave?.epoch == epoch { self.pauseSave = nil }
            if !self.disposed, !self.backgrounded, self.startingEpoch == epoch, !self.wantsPlayback,
               self.player.rate == 0, self.player.timeControlStatus == .paused, self.lease === captured { self.release() }
        }
        pauseSave = (epoch,task)
    }
    private func confirmClockSample() -> (position: TimeInterval, duration: TimeInterval)? {
        guard checkpointReady else { return nil }
        let sample = clock?() ?? (position: player.currentTime().seconds,duration: player.currentItem?.duration.seconds ?? .nan)
        guard sample.position.isFinite, sample.duration.isFinite, sample.duration > 0,
              sample.position >= 0, sample.position <= sample.duration + 0.25 else { return nil }
        if let target = clockTarget {
            // A successful seek callback can precede AVPlayer's observed time.
            guard target <= sample.duration + 0.25, abs(sample.position - target) <= 1.5,
                  target == 0 || sample.position > 0 else { return nil }
            clockTarget = nil
        }
        if let lastClockSample, sample.position + 0.25 < lastClockSample.position { return nil }
        lastClockSample = sample
        reconnectCheckpoint = (sync.accountGeneration,sample.position)
        return sample
    }
    private func saveSample(allowSeeking: Bool = false) -> (position: TimeInterval, duration: TimeInterval)? {
        guard !disposed, !fixture, checkpointReady, allowSeeking || !isSeeking, metadata.isValid, lease != nil || localOnly else { return nil }
        return confirmClockSample() ?? lastClockSample
    }
    private func reloadSource(epoch: UInt64, account: UInt64, allowCachedSource: Bool) async throws {
        guard let refreshSource else { return }
        message = "Reconnecting to the selected source…"
        let current = source
        let task = Task { try await refreshSource(current) }
        sourceRefreshTask = task
        defer { if epoch == startingEpoch { sourceRefreshTask = nil } }
        let refreshed: (source: MediaSource, subtitles: [SubtitleSource])
        do {
            refreshed = try await withTaskCancellationHandler(operation: { try await task.value },onCancel: { task.cancel() })
        } catch ProviderFailure.staleNavigation {
            throw ProviderFailure.staleNavigation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some watch pages no longer expose the selected source menu.
            // For the automatic resume, give the existing ticket one try.
            if allowCachedSource { return }
            throw error
        }
        guard !disposed, !closing, epoch == startingEpoch, account == sync.accountGeneration, !Task.isCancelled else { throw CancellationError() }
        let priorSubtitle = subtitles.first { $0.id == captionSelection }
        source = refreshed.source
        updateSegments(source.segments)
        updateSubtitles(refreshed.subtitles)
        if !automaticCaptions, let priorSubtitle,
           let replacement = subtitles.first(where: { $0.language == priorSubtitle.language && $0.label == priorSubtitle.label }),
           activeSubtitleRequest != SubtitleRequestIdentity(replacement) { selectSubtitle(replacement) }
    }
    func play(explicit: Bool, expectedGeneration: Int64? = nil) async {
        guard !disposed, !closing, !isStarting, !isSeeking, !handoffInProgress else { return }
        let intentEpoch = startingEpoch
        if let pauseSave, pauseSave.epoch == startingEpoch { await pauseSave.task.value }
        guard !disposed, !closing, !isStarting, !isSeeking, !handoffInProgress,
              startingEpoch == intentEpoch, !Task.isCancelled else { return }
        nextEpisodePrompt = nil; finishedGeneration = nil; lastPlaybackGeneration = nil
        isStarting = true; startingEpoch &+= 1; let epoch = startingEpoch
        backgrounded = false; resumeOnForeground = false
        clearScrubWindow()
        let signedIn = sync.isSignedIn, account = sync.accountGeneration
        let requiresOwnedResume = signedIn && expectedGeneration != nil
        let outgoing = previousLease
        let resumeOpenPlayer = !reachedEnd && reconnectCheckpoint?.account == account
        let chosenPosition = explicitPosition ?? (reachedEnd ? 0 : nil)
        if requiresOwnedResume { knownCheckpointAccount = account }
        let cachedCheckpoint = (sync.episodeProgress(animeID: metadata.animeID,episode: metadata.episode) ?? 0) > 0
            && !sync.isEpisodeWatched(animeID: metadata.animeID,episode: metadata.episode)
        let protectsZeroFallback = signedIn && (knownCheckpointAccount == account || cachedCheckpoint)
        defer { if epoch == startingEpoch { claimTask = nil; isStarting = false; restoring = false } }
        restoring = true; player.pause(); restoring = false
        release()
        let fallbackPosition = reconnectCheckpoint?.account == account ? reconnectCheckpoint?.position ?? position : position
        do {
            if clock == nil || itemFactory != nil,
               itemNeedsReload || player.currentItem?.status == .failed || player.currentItem == nil {
                let recovering = itemNeedsReload || player.currentItem?.status == .failed
                itemNeedsReload = true
                if recovering { try await reloadSource(epoch: epoch,account: account,allowCachedSource: requiresOwnedResume) }
                guard !disposed, !closing, epoch == startingEpoch, account == sync.accountGeneration, !Task.isCancelled else { return }
                try await replacePlaybackItem(epoch: epoch)
                guard !disposed, !closing, epoch == startingEpoch, !Task.isCancelled else { return }
            }
            if mediaBridge != nil { try AVAudioSession.sharedInstance().setCategory(.playback,mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) }
            let result: PlaybackStart
            if fixture || !metadata.isValid {
                // Untracked sources are playable, but cannot acquire or write a
                // progress session. Debug fixture playback has the same boundary.
                result = PlaybackStart(allowed: true,lease: nil,resumePosition: nil,message: nil)
            } else {
                let claim = Task { [sync, metadata] in
                    try await sync.begin(metadata: metadata,explicit: explicit,expectedSourceGeneration: expectedGeneration,
                                         resumeOpenPlayer: resumeOpenPlayer && chosenPosition == nil,previousLease: outgoing)
                }
                claimTask = claim
                result = try await withTaskCancellationHandler(operation: { try await claim.value },onCancel: { claim.cancel() })
            }
            guard !disposed, epoch == startingEpoch, !Task.isCancelled else { sync.release(result.lease); return }
            guard result.allowed else {
                explicitPosition = nil; pendingGeneration = nil
                message = result.message ?? "Press Play to continue on this device"; return
            }
            if !fixture, metadata.isValid, result.lease == nil,
               requiresOwnedResume || resumeOpenPlayer && signedIn
                || protectsZeroFallback && explicitPosition == nil && fallbackPosition <= 0 {
                // Do not turn a failed fresh read into an apparent restart.
                // Signed-out playback and intentional offline local starts remain available.
                explicitPosition = nil; pendingGeneration = nil
                message = "Could not read your saved position. Check your connection and press Play again."; return
            }
            lease = result.lease; localOnly = result.lease == nil
            if let owned = result.lease { knownCheckpointAccount = account; previousLease = owned }
            lastPlaybackGeneration = result.lease?.generation
            if let captured = lease {
                invalidation = captured.$isValid.sink { [weak self, weak captured] valid in
                    guard !valid else { return }; Task { @MainActor in guard let self, self.lease === captured else { return }; self.startingEpoch &+= 1; self.cancelPendingStart(); self.isStarting = false; self.wantsPlayback = false; self.restoring = true; self.player.pause(); self.restoring = false; self.release(); self.message = "Playback continued on another device. Press Play to resume here." }
                }
            }
            let at = chosenPosition ?? result.resumePosition ?? fallbackPosition
            explicitPosition = nil; pendingGeneration = nil
            restoring = true
            let completed = await seekForStart(to: max(0,at))
            guard !disposed, !closing, epoch == startingEpoch else { return }
            guard !Task.isCancelled else { release(); return }
            guard result.lease == nil || result.lease?.isValid == true && lease === result.lease else { return }
            guard completed else {
                itemNeedsReload = true; videoReady = false; release()
                message = "The video connection stalled. Press Play to reconnect, or choose another source."; return
            }
            clockTarget = at
            checkpointReady = true
            reachedEnd = false
            _ = confirmClockSample()
            wantsPlayback = true; player.play(); message = "Playing"
        } catch {
            guard !disposed, epoch == startingEpoch, !Task.isCancelled else { return }
            message = itemNeedsReload && refreshSource != nil
                ? "Could not reconnect to this source. Press Play to try again, or choose another source."
                : error.localizedDescription
        }
    }
    func save(ended: Bool = false) async {
        guard let sample = saveSample(), !ended || sample.position >= sample.duration - 2 else { return }
        await sync.progress(metadata: metadata,lease: lease,position: sample.position,duration: sample.duration,ended: ended)
    }
    private func release() {
        invalidation?.cancel(); invalidation = nil
        sync.release(lease); lease = nil; localOnly = false; checkpointReady = false
        lastClockSample = nil; clockTarget = nil
    }
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
        defer { if controlSeekRevision == revision { isSeeking = false } }
        let completed: Bool
        if let seekOperation { await seekOperation(player,target); completed = !Task.isCancelled }
        else { completed = await player.seek(to: CMTime(seconds: target,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) }
        guard completed, !disposed, !closing, epoch == startingEpoch, revision == controlSeekRevision,
              player.currentItem === item, !Task.isCancelled else { return }
        if paused { explicitPosition = target; pendingGeneration = nil }
        lastClockSample = nil; clockTarget = target
        if let sample = saveSample(allowSeeking: true),
           sync.enqueueProgress(metadata: metadata,lease: lease,position: sample.position,duration: sample.duration) {
            Task { [sync] in await sync.flushPending() }
        }
        refreshCaption()
    }
    func updateSegments(_ segments: [PlaybackSegment]) {
        guard self.segments != segments else { return }
        self.segments = segments; refreshSegment()
    }
    private func refreshSegment() {
        let next = canSeek && (localOnly || lease?.isValid == true)
            ? segments.first { $0.contains(position,duration: duration) } : nil
        if activeSegment != next { activeSegment = next }
    }
    func skip(_ segment: PlaybackSegment) async {
        guard (localOnly || lease?.isValid == true), segments.contains(segment),
              segment.contains(position,duration: duration) else { return }
        await seek(to: segment.end)
        refreshSegment()
    }
    func advanceEpisode() {
        guard canSeek, let nextEpisode else { return }
        onNextEpisode?(nextEpisode,lastPlaybackGeneration)
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
        guard !disposed, !closing, !backgrounded else { return }
        backgrounded = true
        let previousPauseSave = pauseSave?.epoch == startingEpoch ? pauseSave?.task : nil
        cancelControlSeek()
        clearScrubWindow()
        let wasPlaying = wantsPlayback
        let ownedGeneration = lease.flatMap { $0.isValid ? $0.generation : nil }
        resumeOnForeground = wasPlaying && ownedGeneration != nil; pendingGeneration = ownedGeneration
        wantsPlayback = false
        if !fixture, player.currentItem != nil, mediaBridge != nil || itemFactory != nil { itemNeedsReload = true }
        startingEpoch &+= 1; cancelPendingStart(); isStarting = false; explicitPosition = nil
        let epoch = startingEpoch, captured = lease
        restoring = true; player.pause(); restoring = false
        if let previousPauseSave { await previousPauseSave.value }
        else { await save() }
        guard !disposed, !closing, epoch == startingEpoch, lease === captured,
              player.rate == 0 else { return }
        release()
        if wasPlaying && ownedGeneration == nil { message = "Press Play to resume on this device." }
    }
    func foreground() async {
        backgrounded = false
        guard resumeOnForeground, !disposed, !closing, let generation = pendingGeneration else { return }; resumeOnForeground = false
        await play(explicit: true,expectedGeneration: generation)
    }
    func handoff() async throws -> HandoffSnapshot {
        guard !disposed, !closing, !isSeeking, !handoffInProgress else { throw CoreError.canceled }
        let capturedPosition = lease == nil ? nil : saveSample()?.position
        if lease != nil && capturedPosition == nil {
            throw CoreError.message("The player hasn't reached the saved position. Try again once playback resumes.")
        }
        handoffInProgress = true
        wantsPlayback = false
        clearScrubWindow()
        startingEpoch &+= 1; cancelPendingStart(); isStarting = false; restoring = true; player.pause(); restoring = false
        let epoch = startingEpoch, capturedLease = lease
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
        handoffInProgress = false; startingEpoch &+= 1; cancelPendingStart(); isStarting = false
        explicitPosition = nil; pendingGeneration = nil; resumeOnForeground = false
        clearScrubWindow()
        restoring = true; player.pause(); restoring = false; release()
        if !disposed { message = "Press Play to resume on this device." }
    }
    func close() async {
        guard !disposed, !closing else { return }; closing = true; startingEpoch &+= 1; cancelPendingStart(); cueTask?.cancel(); restoring = true; player.pause(); restoring = false
        cancelControlSeek()
        clearScrubWindow()
        await save(); release(); disposed = true; handoffInProgress = false
        if let ticks { player.removeTimeObserver(ticks) }; ticks = nil
        itemStatusObservation?.invalidate(); itemStatusObservation = nil
        observers.removeAll(); notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        if let embeddedOutput { player.currentItem?.remove(embeddedOutput.output) }
        embeddedOutput = nil
        player.replaceCurrentItem(with: nil); mediaBridge?.stop(); mediaBridge = nil
    }
    private func refreshCaption() {
        guard !disposed else { return }
        let caption: String
        if captionSelection == "off" { caption = "" }
        else if !cues.isEmpty { caption = SubtitleText.active(cues,at: position - captionDelay) }
        else { caption = originalStyles ? "" : embeddedCaption }
        if caption != captionText { captionText = caption }
    }
    /// The owner fences provider navigation/episode identity before delivering
    /// this full candidate list. A late discovery may not undo a user's choice.
    func updateSubtitles(_ sources: [SubtitleSource]) {
        guard !disposed, !closing, !fixture else { return }
        var seen = Set<String>()
        let next = Array(sources.filter { MediaBridgePolicy.allows($0.url) && !emptySubtitleRequests.contains(SubtitleRequestIdentity($0)) && seen.insert($0.id).inserted }.prefix(32))
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
        cueTask?.cancel(); cues = []; captionSelection = source?.id ?? "off"
        refreshCaption()
        guard let source else {
            Task { [weak self] in await self?.deselectEmbedded(for: epoch) }
            return
        }
        cueTask = Task { [weak self] in
            do {
                var request = URLRequest(url: source.url); request.timeoutInterval = 10
                for (key,value) in MediaBridgePolicy.headers(source.headers) { request.setValue(value,forHTTPHeaderField: key) }
                guard let self else { return }
                let reply = try await self.captionTransport.request(request,maxBytes: 4_000_000)
                guard (200..<300).contains(reply.status), let text = String(data: reply.body,encoding: .utf8) else { throw CoreError.message("Subtitles could not load") }
                let parsed = SubtitleText.parse(text,extension: source.url.pathExtension)
                guard !self.disposed, !Task.isCancelled, epoch == self.subtitleEpoch, self.captionSelection == source.id else { return }
                if parsed.isEmpty {
                    let rejected = SubtitleRequestIdentity(source)
                    self.emptySubtitleRequests.append(rejected)
                    self.subtitles.removeAll { SubtitleRequestIdentity($0) == rejected }
                    self.captionSelection = "automatic"
                    self.activeSubtitleRequest = nil
                    if automatic { self.selectAutomaticExternal() }
                    else { self.message = "No readable subtitles in this track. Try another track or the website player." }
                    return
                }
                await self.deselectEmbedded(for: epoch)
                guard !self.disposed, !self.closing, !Task.isCancelled, epoch == self.subtitleEpoch else { return }
                self.cues = parsed; self.refreshCaption()
            } catch { if !Task.isCancelled { self?.message = "Subtitles could not load. Try another track." } }
        }
    }
    private func deselectEmbedded(for epoch: UInt64) async {
        if let item = player.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
           !disposed, !closing, epoch == subtitleEpoch, player.currentItem === item {
            item.select(nil,in: group)
            embeddedCaption = ""; refreshCaption()
        }
    }
    func selectEmbedded(_ option: AVMediaSelectionOption?) {
        guard !disposed, !closing else { return }
        automaticCaptions = false
        activeSubtitleRequest = nil
        subtitleEpoch &+= 1; let epoch = subtitleEpoch
        cueTask?.cancel(); cues = []; embeddedCaption = ""; captionText = ""; captionSelection = option.map { "embedded:" + $0.displayName } ?? "off"
        guard let item = player.currentItem else { return }
        Task { [weak self] in if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), let self, !self.disposed, epoch == self.subtitleEpoch, self.player.currentItem === item { item.select(option,in: group) } }
    }
    func applyStyles() {
        guard let item = player.currentItem else { return }
        embeddedOutput?.output.suppressesPlayerRendering = !originalStyles
        // The source-placement option still uses the shared font and outline.
        let attributes: [String:Any] = [
            kCMTextMarkupAttribute_FontFamilyName as String: "Roboto",
            kCMTextMarkupAttribute_BoldStyle as String: true,
            kCMTextMarkupAttribute_RelativeFontSize as String: captionSize / 22 * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0,1.0,1.0,1.0],
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0,0.0,0.0,0.0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.0,0.0,0.0,0.0],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: kCMTextMarkupCharacterEdgeStyle_Uniform
        ]
        item.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }
}

/// All geometry is in the host view's coordinates. Captions follow the actual
/// displayed image, never the letterbox/pillarbox or an assumed screen ratio.
enum NativeCaptionLayout {
    static let defaultMargin = 0.025
    static let step = 0.025
    static func margin(_ value: Double) -> Double { value.isFinite ? min(0.20,max(0.0125,value)) : defaultMargin }
    static func bottomInset(region: CGRect,margin: Double) -> CGFloat { max(4,region.height * CGFloat(Self.margin(margin))) }
    static func laneHeight(region: CGRect,fontSize: CGFloat,margin: Double) -> CGFloat {
        bottomInset(region: region,margin: margin) + ceil(fontSize * 2.7) + 8
    }
    static func region(video: CGRect,viewport: CGRect,safeInsets: UIEdgeInsets) -> CGRect {
        guard video.minX.isFinite, video.minY.isFinite, video.width.isFinite, video.height.isFinite, video.width > 0, video.height > 0 else { return .zero }
        let result = video.intersection(viewport.inset(by: safeInsets))
        return result.isNull || result.isEmpty ? .zero : result
    }
    static func visiblePicture(video: CGRect,viewport: CGRect,safeViewport: CGRect) -> CGRect {
        // The playback controls still use the full safe area. Dialogue uses
        // the picture edge with its own inset, while respecting side cutouts.
        let verticalBounds = CGRect(x: safeViewport.minX,y: safeViewport.minY,width: safeViewport.width,
                                    height: max(0,viewport.maxY - safeViewport.minY))
        let clipped = video.intersection(verticalBounds)
        return clipped.isNull || clipped.isEmpty ? .zero : clipped
    }
    static func fontSize(preference: Double,videoHeight: CGFloat) -> CGFloat {
        let chosen = preference.isFinite ? preference : 22
        return min(96,max(10,videoHeight * 0.06 * CGFloat(chosen / 22)))
    }
    static func available(region: CGRect,margin: Double,controls: CGRect?,header: CGRect? = nil,preferAboveControls: Bool = false) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        var top = region.minY + 4
        var bottom = region.maxY - bottomInset(region: region,margin: margin)
        if let controls, !controls.isEmpty, controls.intersects(region) {
            let lowerTop = controls.maxY + 6
            if !preferAboveControls, bottom - lowerTop >= min(22,region.height * 0.10) { top = max(top,lowerTop) }
            else { bottom = min(bottom,controls.minY - 12) }
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
    static func frame(region: CGRect,textSize: CGSize,margin: Double,controls: CGRect?,header: CGRect? = nil,padding: CGSize = CGSize(width: 4,height: 2),preferAboveControls: Bool = false) -> CGRect {
        let space = available(region: region,margin: margin,controls: controls,header: header,preferAboveControls: preferAboveControls)
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
    let shortcuts: CGRect
    let transportCenter: CGPoint
    static let timelineDockHeight: CGFloat = 52
    static let shortcutHeight: CGFloat = 44
    static func fitted(video: CGRect,viewport: CGRect,safeInsets: UIEdgeInsets,safeViewport: CGRect? = nil,headerHeight: CGFloat = 44,dockHeight: CGFloat = 96,captionLane: CGFloat = 0,controlsVisible: Bool = false) -> NativeChromeLayout {
        let safe = (safeViewport ?? viewport.inset(by: safeInsets)).intersection(viewport)
        guard safe.width > 0, safe.height > 0 else { return NativeChromeLayout(header: .zero,dock: .zero,shortcuts: .zero,transportCenter: .zero) }
        let clipped = video.intersection(safe)
        let content = clipped.isNull || clipped.isEmpty ? safe : clipped
        let gap: CGFloat = 8
        let imageWidth = min(safe.width,max(min(320,safe.width),content.width - gap * 2))
        let landscape = viewport.width > viewport.height
        let width = landscape ? min(600,max(0,safe.width - 2 * gap),max(248,safe.width * 0.70)) : imageWidth
        let center = landscape ? safe.midX : content.midX
        let left = min(safe.maxX - width,max(safe.minX,center - width / 2))
        let portraitTop = content.minY - safe.minY >= headerHeight + gap ? content.minY - headerHeight - gap : content.minY + gap
        let shortcutSpace = controlsVisible ? shortcutHeight : 0
        let portraitDockY = safe.maxY - content.maxY >= dockHeight + gap + shortcutSpace
            ? content.maxY + gap + shortcutSpace : content.maxY - dockHeight - gap
        let top = landscape ? safe.minY + gap : portraitTop
        let bottom = landscape ? safe.maxY - dockHeight - gap : portraitDockY
        let headerY = max(safe.minY,min(safe.maxY - headerHeight,top))
        var dockY = max(safe.minY,min(safe.maxY - dockHeight,bottom))
        if !landscape, bottom < content.maxY, captionLane > 0 {
            let lifted = min(viewport.maxY,video.maxY) - captionLane - dockHeight
            if lifted >= headerY + headerHeight + gap { dockY = min(dockY,lifted) }
        }
        let dock = CGRect(x: left,y: dockY,width: width,height: dockHeight)
        let shortcutRight = controlsVisible ? dock.maxX : content.maxX - gap
        let shortcutWidth = controlsVisible ? dock.width : min(144,max(0,content.width - gap * 2))
        let shortcutBottom = controlsVisible ? dock.minY : content.maxY - max(gap,captionLane)
        let shortcuts = CGRect(x: shortcutRight - shortcutWidth,
                               y: max(safe.minY,shortcutBottom - shortcutHeight),
                               width: shortcutWidth,height: shortcutHeight)
        return NativeChromeLayout(header: CGRect(x: left,y: headerY,width: width,height: headerHeight),
                                  dock: dock,shortcuts: shortcuts,transportCenter: CGPoint(x: content.midX,y: content.midY))
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
    var captionMargin = NativeCaptionLayout.defaultMargin
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
        let region = NativeCaptionLayout.visiblePicture(video: video,viewport: view.bounds,safeViewport: safe)
        geometry?.report(region,safeViewport: safe)
        #if DEBUG
        qaVideoRegion.frame = region
        #endif
        guard !captionText.isEmpty, region.width > 0, region.height > 0 else { caption.isHidden = true; return }
        let landscape = view.bounds.width > view.bounds.height
        let space = NativeCaptionLayout.available(region: region,margin: captionMargin,controls: controlsFrame,header: headerFrame,preferAboveControls: landscape)
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
        caption.frame = NativeCaptionLayout.frame(region: region,textSize: size,margin: captionMargin,controls: controlsFrame,header: headerFrame,padding: .zero,preferAboveControls: landscape)
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
        @objc func swipe(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended,
                  Self.isBackSwipe(gesture.translation(in: gesture.view), minimum: 96, horizontalRatio: 2) else { return }
            model.onClose?()
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer { return true }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return Self.isBackSwipe(pan.velocity(in: pan.view), minimum: 0, horizontalRatio: 1.5)
        }
        static func isBackSwipe(_ movement: CGPoint, minimum: CGFloat, horizontalRatio: CGFloat) -> Bool {
            let leftwardDistance = -movement.x
            return leftwardDistance > minimum && leftwardDistance > abs(movement.y) * horizontalRatio
        }
        static func acceptsVideoTouch(_ original: UIView?) -> Bool { var current = original; while let v = current { if v is UIControl || v is UIScrollView || String(describing: type(of: v)).localizedCaseInsensitiveContains("scrub") { return false }; current = v.superview }; return true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldReceive touch: UITouch) -> Bool { Self.acceptsVideoTouch(touch.view) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
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

@MainActor private struct NativeTransportControls: View {
    @ObservedObject var model: NativePlaybackModel
    let playing: Bool
    let layout: NativeChromeLayout
    let landscape: Bool
    var onInteraction: () -> Void
    var onScrubbing: (Bool) -> Void
    @State private var draft: Double?
    @State private var editing = false
    @State private var seekTask: Task<Void,Never>?
    @State private var pendingSeek: Double?
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only the timeline clock needs a periodic refresh.
            TimelineView(.animation(minimumInterval: 0.5,paused: !playing)) { _ in timeline }
                .padding(.horizontal,12)
                .padding(.bottom,6)
                .frame(width: layout.dock.width,height: layout.dock.height)
                .background(.black.opacity(0.65),in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .contain).accessibilityIdentifier("player.transport")
                .position(x: layout.dock.midX,y: layout.dock.midY)
            centerControls
                .position(x: layout.transportCenter.x,y: layout.transportCenter.y)
        }.foregroundStyle(.white)
            .onDisappear { seekTask?.cancel(); pendingSeek = nil; onScrubbing(false) }
    }

    private var centerControls: some View {
        let skipSize: CGFloat = landscape ? 48 : 44
        let playSize: CGFloat = landscape ? 56 : 52
        return HStack(spacing: landscape ? 32 : 24) {
            Button { skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: landscape ? 24 : 22))
            }.buttonStyle(PlaybackTransportButtonStyle(size: skipSize))
                .accessibilityLabel("Back ten seconds").accessibilityIdentifier("player.skip.back")
                .disabled(!model.canSeek)
            Button {
                onInteraction()
                if model.wantsPlayback { model.pause() }
                else { Task { await model.play(explicit: true) } }
            } label: {
                Image(systemName: model.wantsPlayback ? "pause.fill" : model.reachedEnd ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: landscape ? 30 : 26,weight: .semibold))
            }.buttonStyle(PlaybackTransportButtonStyle(size: playSize))
                .accessibilityLabel(model.wantsPlayback ? "Pause" : model.reachedEnd ? "Replay" : "Play")
                .accessibilityIdentifier("player.play-pause")
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
                Image(systemName: "goforward.10").font(.system(size: landscape ? 24 : 22))
            }.buttonStyle(PlaybackTransportButtonStyle(size: skipSize))
                .accessibilityLabel("Forward ten seconds").accessibilityIdentifier("player.skip.forward")
                .disabled(!model.canSeek)
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading,spacing: 0) {
            Text(Self.time(draft ?? model.position) + "/" + Self.time(model.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity,alignment: .leading)
                .frame(height: 22)
                .accessibilityLabel("Playback position").accessibilityIdentifier("player.time")
                .overlay(alignment: .trailing) {
                    if model.isStarting || model.isSeeking { ProgressView().controlSize(.small) }
                }
            Slider(value: Binding(get: { min(max(0,draft ?? model.position),max(1,model.duration)) },set: { value in
                draft = value
                if !editing { commit(value) }
            }),in: 0...max(1,model.duration),onEditingChanged: { value in
                editing = value; onScrubbing(value); onInteraction()
                if value { draft = model.position }
                else if let draft { commit(draft) }
            }).tint(.white).disabled(!model.canSeek && !editing)
                .frame(height: 24)
                .accessibilityLabel("Episode timeline").accessibilityIdentifier("player.timeline")
        }
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
            .alert("Episode finished",isPresented: Binding(
                get: { model.nextEpisodePrompt != nil },set: { if !$0 { model.nextEpisodePrompt = nil } }),
                presenting: model.nextEpisodePrompt
            ) { episode in
                Button("Play next episode") { model.onNextEpisode?(episode,model.finishedGeneration) }
                Button("Back to episodes",role: .cancel) { model.onClose?() }
            } message: { episode in
                Text("Episode \(episode.number)")
            }
            .sheet(isPresented: $captions) { SubtitleSettings(model: model) }
            .sheet(isPresented: $options) { PlaybackOptions(model: model) }
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
            NativePlayerController(model: model,onVideoTap: {
                #if DEBUG
                // XCTest waits for idleness before delivering each tap.
                toolbar.toggleFromVideoTap(hideAfter: model.fixture ? 15_000_000_000 : nil)
                #else
                toolbar.toggleFromVideoTap()
                #endif
            },controlsFrame: toolbar.visible ? layout.dock.union(layout.shortcuts) : nil,
                                   headerFrame: toolbar.visible ? layout.header : nil,geometry: videoGeometry)
            if toolbar.visible, !videoGeometry.safeViewport.isEmpty {
                chrome(layout: layout,landscape: geometry.size.width > geometry.size.height).transition(.opacity)
            }
            if (toolbar.visible || model.activeSegment != nil), !layout.shortcuts.isEmpty {
                shortcuts(in: layout.shortcuts)
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
        }
            #if DEBUG
            .onPreferenceChange(QAPauseButtonFrameKey.self) { frame in
                if !frame.isEmpty, frame != qaPauseFrame { qaPauseFrame = frame }
            }
            #endif
    }
    private func chromeLayout(in geometry: GeometryProxy) -> NativeChromeLayout {
        let insets = geometry.safeAreaInsets
        let region = videoGeometry.region
        let captionLane = model.captionsEnabled && (!model.originalStyles || model.showingExternalCaption)
            ? NativeCaptionLayout.laneHeight(region: region,fontSize: NativeCaptionLayout.fontSize(preference: model.captionSize,videoHeight: region.height),margin: model.captionMargin) : 0
        return NativeChromeLayout.fitted(video: videoGeometry.region,viewport: CGRect(origin: .zero,size: geometry.size),
                                         safeInsets: UIEdgeInsets(top: insets.top,left: insets.leading,bottom: insets.bottom,right: insets.trailing),
                                         safeViewport: videoGeometry.safeViewport.isEmpty ? nil : videoGeometry.safeViewport,
                                         headerHeight: geometry.size.width > geometry.size.height ? 48 : 44,dockHeight: NativeChromeLayout.timelineDockHeight,captionLane: captionLane,controlsVisible: toolbar.visible)
    }
    private func chrome(layout: NativeChromeLayout,landscape: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            controls(landscape: landscape).frame(width: layout.header.width,height: layout.header.height)
                .position(x: layout.header.midX,y: layout.header.midY)
            NativeTransportControls(model: model,playing: playing,layout: layout,landscape: landscape,onInteraction: { toolbar.reveal() },onScrubbing: {
                scrubbing = $0; updateToolbar()
            })
        }
    }
    private func shortcuts(in frame: CGRect) -> some View {
        HStack(spacing: 5) {
            if toolbar.visible {
                Button("+90s") {
                    toolbar.reveal()
                    Task { await model.seek(to: model.position + 90) }
                }.accessibilityLabel("Forward 90 seconds").accessibilityIdentifier("player.skip.90")
                    .disabled(!model.canSeek)
                if model.nextEpisode != nil {
                    Button {
                        toolbar.reveal(); model.advanceEpisode()
                    } label: {
                        Label("Next episode",systemImage: "forward.end.fill")
                    }.accessibilityIdentifier("player.next-episode").disabled(!model.canSeek)
                }
            }
            if let segment = model.activeSegment {
                Button(segment.kind.title) { Task { await model.skip(segment) } }
                    .accessibilityIdentifier("player.skip." + segment.kind.rawValue)
            }
        }.buttonStyle(PlaybackShortcutStyle())
            .frame(width: frame.width,alignment: .trailing)
            .position(x: frame.midX,y: frame.midY)
    }

    private func controls(landscape: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.onClose?() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back").accessibilityIdentifier("player.close")
            Text(model.metadata.title)
                .font((landscape ? Font.body : .subheadline).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { toolbar.reveal(); captions = true } label: { Image(systemName: "captions.bubble") }
                .accessibilityLabel("Subtitles").accessibilityIdentifier("player.subtitles")
            Button { toolbar.reveal(); onTV() } label: {
                Image("tv-connect").resizable().renderingMode(.template).scaledToFit()
                    .frame(width: landscape ? 23 : 20,height: landscape ? 23 : 20)
            }
                .accessibilityLabel("Play on TV").disabled(model.isSeeking || model.handoffInProgress)
            Button { toolbar.reveal(); options = true } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Playback options").accessibilityIdentifier("player.options")
        }.buttonStyle(PlaybackIconButtonStyle(landscape: landscape)).foregroundStyle(.white)
            .padding(.horizontal,4)
            .background { Capsule().fill(.black.opacity(0.45)).frame(height: landscape ? 48 : 44) }
    }
    private func updateToolbar(playing: Bool? = nil) {
        toolbar.update(playing: playing ?? (model.player.timeControlStatus == .playing),active: appeared && scenePhase == .active,
                       presenting: captions || options || tvPanelPresented || scrubbing || model.isSeeking || model.isStarting,voiceOver: voiceOver)
    }
}

private struct PlaybackTransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.45))
            .frame(width: size,height: size)
            .background(Color(white: configuration.isPressed ? 0.38 : 0.294).opacity(0.86),in: Circle())
            .contentShape(Circle())
    }
}

private struct PlaybackShortcutStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12,weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.45))
            .padding(.horizontal,10)
            .frame(minWidth: 44,minHeight: NativeChromeLayout.shortcutHeight)
            .background(.black.opacity(configuration.isPressed ? 0.95 : 0.78),in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.18)) }
            .contentShape(Capsule())
    }
}

private struct PlaybackIconButtonStyle: ButtonStyle {
    let landscape: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: landscape ? 21 : 18,weight: .semibold))
            .frame(width: landscape ? 48 : 44,height: landscape ? 48 : 44)
            .contentShape(Rectangle())
            .background { Circle().fill(.white.opacity(configuration.isPressed ? 0.15 : 0)).frame(width: landscape ? 48 : 44) }
    }
}
private struct PlaybackOptions: View {
    @ObservedObject var model: NativePlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var muted = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DisclosureGroup("Speed") {
                        ForEach(NativePlaybackModel.playbackSpeeds,id: \.self) { speed in
                            let label = speed == 1 ? "Normal" : speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
                            PlaybackSettingChoice(label: label,selected: model.playbackSpeed == speed) {
                                model.setPlaybackSpeed(speed)
                            }
                        }
                    }
                    DisclosureGroup("Audio") {
                        PlaybackSettingChoice(label: "Auto",selected: model.selectedAudio == nil) { model.selectAudio(nil) }
                        ForEach(Array(model.audioOptions.enumerated()),id: \.offset) { _,option in
                            PlaybackSettingChoice(label: option.displayName,selected: model.selectedAudio == option) {
                                model.selectAudio(option)
                            }
                        }
                    }
                    Button(muted ? "Unmute" : "Mute") {
                        model.player.isMuted.toggle()
                        muted = model.player.isMuted
                    }
                    if let fallback = model.onFallback {
                        Button("Use website player") { dismiss(); fallback() }
                    }
                }
            }
            .navigationTitle("Playback options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("player.options.done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { muted = model.player.isMuted }
    }
}

private struct PlaybackSettingChoice: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SubtitleSettings: View {
    @ObservedObject var model: NativePlaybackModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Tracks") {
                    choice("Off",selected: model.captionSelection == "off") { model.selectSubtitle(nil) }
                        .accessibilityIdentifier("player.subtitle.off")
                    ForEach(Array(model.embeddedOptions.enumerated()),id: \.offset) { _,option in
                        choice(option.displayName,selected: model.captionSelection == "embedded:" + option.displayName) { model.selectEmbedded(option) }
                    }
                    ForEach(Array(model.subtitles.enumerated()),id: \.offset) { index,source in
                        choice(source.label,selected: model.captionSelection == source.id) { model.selectSubtitle(source) }
                            .accessibilityIdentifier("player.subtitle.track.\(index)")
                    }
                    if model.embeddedOptions.isEmpty && model.subtitles.isEmpty { Text("No selectable subtitles found for this source.") }
                }
                Section("Appearance") {
                    let sizes: [(String,Double)] = [("Small",17),("Medium",22),("Large",27),("Extra large",32)]
                    // Older builds let people adjust the size in smaller steps.
                    let savedSize = model.captionSize.isFinite ? model.captionSize : 22
                    let selected = sizes.indices.min { abs(sizes[$0].1 - savedSize) < abs(sizes[$1].1 - savedSize) }
                    ForEach(sizes.indices,id: \.self) { index in
                        choice(sizes[index].0,selected: index == selected) { model.captionSize = sizes[index].1 }
                            .accessibilityIdentifier(index == 2 ? "player.subtitle.larger" : "player.subtitle.size.\(index)")
                    }
                    Button("Raise subtitles") { model.captionMargin = NativeCaptionLayout.margin(model.captionMargin + NativeCaptionLayout.step) }.accessibilityIdentifier("player.subtitle.raise")
                    Button("Lower subtitles") { model.captionMargin = NativeCaptionLayout.margin(model.captionMargin - NativeCaptionLayout.step) }
                    Button("Reset position") { model.captionMargin = NativeCaptionLayout.defaultMargin }
                }
                if !model.embeddedOptions.isEmpty || model.showingExternalCaption {
                    Section {
                        DisclosureGroup("Advanced") {
                            if !model.embeddedOptions.isEmpty {
                                Toggle("Use source placement",isOn: $model.originalStyles).accessibilityIdentifier("player.subtitle.style")
                            }
                            if model.showingExternalCaption {
                                Slider(value: $model.captionDelay,in: -10...10,step: 0.5)
                                    .accessibilityLabel("Subtitle timing")
                                Text(String(format: "Subtitle timing: %+.1f s",model.captionDelay)).font(.footnote)
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("player.subtitle.settings").navigationTitle("Subtitles").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("player.subtitle.done") } }
        }.preferredColorScheme(.dark)
    }
    private func choice(_ name: String,selected: Bool,action: @escaping () -> Void) -> some View {
        PlaybackSettingChoice(label: name,selected: selected,action: action)
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
