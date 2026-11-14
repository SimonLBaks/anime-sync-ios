import XCTest
import Foundation
import AVFoundation
import Combine
import UIKit
import CoreMedia
@testable import AnimeSync

@MainActor private final class PlaybackMemorySecrets: CoreSecrets {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws { values[key] = data }
}

@MainActor private final class PlaybackHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var respond: ((URLRequest) async throws -> HTTPReply)!
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply {
        requests.append(request)
        return try await respond(request)
    }
}

@MainActor private final class PlaybackGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var openAlready = false
    private var announced = false
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async {
        if !announced { announced = true; started.fulfill() }
        if openAlready { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { openAlready = true; continuation?.resume(); continuation = nil }
}

/// Real NativePlaybackModel, AVPlayer rate/KVO and gated SyncService transport.
/// A clock and immediate seek acknowledgement replace absent media; no decoder
/// or network video is claimed here. Real AVPlayer rate/KVO is still observed.
/// Actual readyForDisplay is a separate simulator UI assertion.
@MainActor final class NativePlaybackTests: XCTestCase {
    private var models: [NativePlaybackModel] = []
    private var gates: [PlaybackGate] = []
    private var tasks: [Task<Void, Never>] = []
    private var suites: [(String, UserDefaults)] = []
    private var metadata: AnimeMetadata {
        AnimeMetadata(animeID: "21",episode: "6",title: "QA playback",watchURL: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=6")!)
    }
    private func object(_ request: URLRequest) throws -> JSONObject {
        try JSONValue.parseObject(XCTUnwrap(request.httpBody))
    }
    private func reply(_ object: JSONObject, status: Int = 200) throws -> HTTPReply {
        HTTPReply(status: status,body: try JSONEncoder().encode(object))
    }
    private func snapshot(_ generation: Int64, session: String = "", position: TimeInterval = 120, completed: Bool = false) -> JSONObject {
        ["sync": .object(["generation": .integer(generation),"session_id": .string(session)]),
         "progress": .object(["current_time": .number(position),"duration": .number(1000),"completed": .bool(completed)])]
    }
    private func make(_ http: PlaybackHTTP, fixture: Bool = false, metadata item: AnimeMetadata? = nil, generation: Int64? = nil, captionTransport: HTTPTransport? = nil, clock: (() -> (position: TimeInterval,duration: TimeInterval))? = nil, seek: ((AVPlayer,TimeInterval) async -> Void)? = nil, startupSeekTimeout: TimeInterval = 12, itemFactory: ((MediaSource) async throws -> AVPlayerItem)? = nil) throws -> NativePlaybackModel {
        let name = "qa-ios-player-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name)); suites.append((name,preferences))
        let secrets = PlaybackMemorySecrets()
        secrets.values["sync.session"] = try JSONEncoder().encode([
            "origin": .string(AppWebPolicy.home.absoluteString),
            "token": .string("as-session-v1.fixture_12345678901234567890"),
            "deviceID": .string("ios-player-fixture")
        ] as JSONObject)
        let sync = SyncService(transport: http,secrets: secrets,preferences: preferences)
        let model = NativePlaybackModel(metadata: item ?? metadata,
                                        source: MediaSource(url: URL(string: "https://example.invalid/fixture.mp4")!),
                                        subtitles: [],sync: sync,fixture: fixture,generation: generation,clock: clock ?? { (position: 120,duration: 1000) },captionTransport: captionTransport,seekOperation: seek ?? { _,_ in },startupSeekTimeout: startupSeekTimeout,itemFactory: itemFactory)
        model.player.isMuted = true
        models.append(model)
        return model
    }
    private func gate(_ name: String) -> PlaybackGate {
        let value = PlaybackGate(expectation(description: name)); gates.append(value); return value
    }
    private func defaultResponse(_ request: URLRequest) throws -> HTTPReply {
        if request.httpMethod == "GET" { return try reply(snapshot(1)) }
        if request.url?.path == "/api/playback" { return try reply(snapshot(2)) }
        return try reply(["ok": .bool(true)])
    }
    private func silentAudioAsset() throws -> URL {
        let asset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let byteCount: UInt32 = 8_000 * 2 * 30
        var wave = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        append(byteCount + 36); wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        wave.append(contentsOf: "data".utf8); append(byteCount); wave.append(Data(count: Int(byteCount)))
        try wave.write(to: asset)
        return asset
    }
    override func tearDown() async throws {
        gates.forEach { $0.open() }
        for task in tasks { await task.value }
        for model in models { await model.close() }
        models.removeAll(); gates.removeAll(); tasks.removeAll()
        for (name,preferences) in suites { preferences.removePersistentDomain(forName: name) }
        suites.removeAll()
        try await super.tearDown()
    }

    func testToolbarPlayingDeadlineHidesAndVideoInteractionStartsANewDeadline() async {
        let first = gate("first toolbar deadline"), second = gate("revealed toolbar deadline")
        var starts = 0
        let toolbar = PlaybackToolbarState { delay in
            XCTAssertEqual(delay,4_000_000_000)
            starts += 1
            if starts == 1 { await first.wait() } else { await second.wait() }
        }
        defer { toolbar.stop() }
        toolbar.update(playing: true,active: true,presenting: false,voiceOver: false)
        await fulfillment(of: [first.started],timeout: 2)
        XCTAssertTrue(toolbar.visible)
        first.open(); for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(toolbar.visible)
        toolbar.toggleFromVideoTap()
        XCTAssertTrue(toolbar.visible)
        await fulfillment(of: [second.started],timeout: 2)
        second.open(); for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(toolbar.visible); XCTAssertEqual(starts,2)
    }

    func testVideoTapTogglesPausedControlsAndKeepsModalAndVoiceOverControlsVisible() {
        let toolbar = PlaybackToolbarState { _ in XCTFail("Paused playback must not schedule auto-hide") }
        toolbar.update(playing: false,active: true,presenting: false,voiceOver: false)
        toolbar.toggleFromVideoTap()
        XCTAssertFalse(toolbar.visible)
        toolbar.update(playing: false,active: true,presenting: false,voiceOver: false)
        XCTAssertFalse(toolbar.visible,"A repeated paused update must preserve manual dismissal")
        toolbar.toggleFromVideoTap()
        XCTAssertTrue(toolbar.visible)
        for state in [(true,true,false),(true,false,true),(false,false,false)] {
            toolbar.update(playing: false,active: state.0,presenting: state.1,voiceOver: state.2)
            toolbar.toggleFromVideoTap()
            XCTAssertTrue(toolbar.visible)
        }
    }

    func testToolbarPausePresentationVoiceOverAndDisappearanceCancelOldDeadlines() async {
        let old = gate("toolbar deadline before pause"), resumed = gate("toolbar deadline after blockers")
        var starts = 0
        let toolbar = PlaybackToolbarState { _ in
            starts += 1
            if starts == 1 { await old.wait() } else { await resumed.wait() }
        }
        defer { toolbar.stop() }
        toolbar.update(playing: true,active: true,presenting: false,voiceOver: false)
        await fulfillment(of: [old.started],timeout: 2)
        for state in [(false,true,false,false),(true,true,true,false),(true,true,false,true),(true,false,false,false)] {
            toolbar.update(playing: state.0,active: state.1,presenting: state.2,voiceOver: state.3)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(toolbar.visible); XCTAssertEqual(starts,1,"Blocked controls must not arm a hide timer")
        }
        toolbar.update(playing: true,active: true,presenting: false,voiceOver: false)
        await fulfillment(of: [resumed.started],timeout: 2)
        old.open(); for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(toolbar.visible,"A canceled old deadline cannot hide the newly revealed toolbar")
        toolbar.stop(); resumed.open(); for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(toolbar.visible,"A detached screen cannot be hidden by a late timer")
    }

    func testVideoTapObservationDoesNotCancelControlsOrClaimScrubberTouches() throws {
        let http = PlaybackHTTP(), model = try make(http)
        let coordinator = NativePlayerController.Coordinator(model,onVideoTap: {})
        let tap = coordinator.videoTapRecognizer()
        XCTAssertFalse(tap.cancelsTouchesInView); XCTAssertFalse(tap.delaysTouchesBegan); XCTAssertFalse(tap.delaysTouchesEnded)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(tap))
        XCTAssertTrue(coordinator.gestureRecognizer(tap,shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
        let video = UIView(), button = UIButton(), slider = UISlider(), scroll = UIScrollView()
        XCTAssertTrue(NativePlayerController.Coordinator.acceptsVideoTouch(video))
        for control in [button,slider,scroll] as [UIView] {
            let descendant = UIView(); control.addSubview(descendant)
            XCTAssertFalse(NativePlayerController.Coordinator.acceptsVideoTouch(descendant))
        }
    }

    func testPlayerBackSwipeRequiresEnoughLeftwardHorizontalMovement() {
        let coordinator = NativePlayerController.Coordinator.self
        XCTAssertTrue(coordinator.isBackSwipe(CGPoint(x: -120,y: 20),minimum: 0,horizontalRatio: 1.5))
        XCTAssertFalse(coordinator.isBackSwipe(CGPoint(x: 120,y: 20),minimum: 0,horizontalRatio: 1.5))
        XCTAssertTrue(coordinator.isBackSwipe(CGPoint(x: -120,y: 20),minimum: 96,horizontalRatio: 2))
        XCTAssertFalse(coordinator.isBackSwipe(CGPoint(x: 120,y: 20),minimum: 96,horizontalRatio: 2))
        XCTAssertFalse(coordinator.isBackSwipe(CGPoint(x: -90,y: 0),minimum: 96,horizontalRatio: 2))
        XCTAssertFalse(coordinator.isBackSwipe(CGPoint(x: -120,y: 80),minimum: 96,horizontalRatio: 2))
    }

    func testCaptionLayoutUsesVideoBoundsWithoutPillarStripsAndAvoidsVisibleTransport() {
        let viewport = CGRect(x: 0,y: 0,width: 852,height: 393)
        let video = CGRect(x: 164,y: 0,width: 524,height: 393)
        let safe = UIEdgeInsets(top: 0,left: 59,bottom: 21,right: 59)
        let region = NativeCaptionLayout.region(video: video,viewport: viewport,safeInsets: safe)
        let text = CGSize(width: 280,height: 46)
        let hidden = NativeCaptionLayout.frame(region: region,textSize: text,margin: 0.1,controls: nil)
        let rail = CGRect(x: 67,y: 271,width: 718,height: 97)
        let visible = NativeCaptionLayout.frame(region: region,textSize: text,margin: 0.1,controls: rail)
        XCTAssertTrue(video.contains(hidden)); XCTAssertTrue(region.contains(visible))
        XCTAssertEqual(hidden.width,288); XCTAssertLessThan(hidden.width,video.width)
        XCTAssertEqual(hidden.midX,video.midX)
        XCTAssertLessThanOrEqual(visible.maxY,rail.minY - 12)
        XCTAssertLessThan(visible.maxY,hidden.maxY)
        let portraitVideo = CGRect(x: 0,y: 286,width: 402,height: 302)
        let portraitViewport = CGRect(x: 0,y: 0,width: 402,height: 874)
        let portraitRegion = NativeCaptionLayout.region(video: portraitVideo,viewport: portraitViewport,safeInsets: UIEdgeInsets(top: 62,left: 0,bottom: 34,right: 0))
        let portrait = NativeCaptionLayout.frame(region: portraitRegion,textSize: text,margin: 0.1,controls: CGRect(x: 12,y: 730,width: 378,height: 100))
        XCTAssertTrue(portraitVideo.contains(portrait),"Portrait captions stay over the picture rather than in its lower black letterbox")
        XCTAssertEqual(NativeCaptionLayout.region(video: .zero,viewport: viewport,safeInsets: .zero),.zero)
        XCTAssertEqual(NativeCaptionLayout.fontSize(preference: 22,videoHeight: 300),18,accuracy: 0.001)
        XCTAssertEqual(NativeCaptionLayout.fontSize(preference: 33,videoHeight: 300),27,accuracy: 0.001)
        XCTAssertEqual(NativeCaptionLayout.fontSize(preference: 22,videoHeight: 600),36,accuracy: 0.001)
        XCTAssertLessThanOrEqual(NativeCaptionLayout.fontSize(preference: 44,videoHeight: 2000),96)
        XCTAssertGreaterThanOrEqual(NativeCaptionLayout.fontSize(preference: 14,videoHeight: 100),10)
    }

    func testLongCaptionFitsTheUsableSpaceAboveTheDockInsteadOfOverlappingIt() {
        let region = CGRect(x: 0,y: 0,width: 600,height: 300)
        let dock = CGRect(x: 0,y: 180,width: 600,height: 120)
        let oldFailure = NativeCaptionLayout.frame(region: region,textSize: CGSize(width: 400,height: 220),margin: 0.1,controls: dock)
        XCTAssertLessThanOrEqual(oldFailure.maxY,168,"The former y=4/maxY=228 result overlapped the dock by 48 points")
        XCTAssertTrue(region.contains(oldFailure))
        let header = CGRect(x: 8,y: 8,width: 584,height: 44)
        let space = NativeCaptionLayout.available(region: region,margin: 0.1,controls: dock,header: header)
        let label = UILabel(); label.numberOfLines = 0
        label.text = Array(repeating: "This longer caption must remain fully above the playback controls.",count: 6).joined(separator: " ")
        let available = CGSize(width: space.width - 8,height: space.height - 4)
        func measure(_ size: CGFloat) -> CGSize {
            label.font = .systemFont(ofSize: size,weight: .semibold)
            return label.sizeThatFits(CGSize(width: available.width,height: .greatestFiniteMagnitude))
        }
        XCTAssertGreaterThan(measure(36).height,available.height)
        let font = NativeCaptionLayout.fittedFontSize(preferred: 36,available: available,measure: measure)
        let text = measure(font)
        XCTAssertLessThan(font,36); XCTAssertGreaterThanOrEqual(font,10)
        XCTAssertLessThanOrEqual(text.height,available.height)
        let fitted = NativeCaptionLayout.frame(region: region,textSize: text,margin: 0.1,controls: dock,header: header)
        XCTAssertTrue(space.contains(fitted)); XCTAssertLessThanOrEqual(fitted.maxY,dock.minY - 12)
        XCTAssertGreaterThanOrEqual(fitted.minY,header.maxY + 8)
        XCTAssertTrue(NativeCaptionLayout.available(region: region,margin: 0.1,controls: CGRect(x: 0,y: 8,width: 600,height: 292)).isEmpty)
    }

    func testStandardCaptionsClearVisibleControlsAndReturnToThePictureEdge() {
        XCTAssertEqual(NativeCaptionLayout.defaultMargin,0.025)
        for viewport in [CGRect(x: 0,y: 0,width: 852,height: 393),CGRect(x: 0,y: 0,width: 402,height: 874)] {
            let landscape = viewport.width > viewport.height
            let video = landscape
                ? viewport.insetBy(dx: 76,dy: 0) : CGRect(x: 0,y: 268,width: 402,height: 226)
            let margin = NativeCaptionLayout.defaultMargin
            let font = NativeCaptionLayout.fontSize(preference: 22,videoHeight: video.height)
            let lane = NativeCaptionLayout.laneHeight(region: video,fontSize: font,margin: margin)
            let layout = NativeChromeLayout.fitted(video: video,viewport: viewport,safeInsets: .zero,captionLane: lane,controlsVisible: true)
            let controls = layout.dock.union(layout.shortcuts)
            let size = CGSize(width: 180,height: 40)
            let shown = NativeCaptionLayout.frame(region: video,textSize: size,margin: margin,controls: controls,header: layout.header,preferAboveControls: landscape)
            let hidden = NativeCaptionLayout.frame(region: video,textSize: size,margin: margin,controls: nil)
            XCTAssertFalse(shown.isEmpty)
            XCTAssertEqual(video.maxY - hidden.maxY,NativeCaptionLayout.bottomInset(region: video,margin: margin),accuracy: 0.1)
            XCTAssertFalse(shown.intersects(controls))
            XCTAssertEqual(shown.maxY,landscape ? controls.minY - 12 : hidden.maxY,accuracy: 0.1)
        }
    }

    func testCaptionUsesTheVideoEdgeAndKeepsTheSideCutoutClear() {
        let viewport = CGRect(x: 0,y: 0,width: 852,height: 393)
        let safe = viewport.inset(by: UIEdgeInsets(top: 0,left: 59,bottom: 21,right: 59))
        let video = viewport.insetBy(dx: 28,dy: 0)
        let picture = NativeCaptionLayout.visiblePicture(video: video,viewport: viewport,safeViewport: safe)
        XCTAssertEqual(picture.minX,safe.minX)
        XCTAssertEqual(picture.maxX,safe.maxX)
        XCTAssertEqual(picture.maxY,video.maxY)
        let frame = NativeCaptionLayout.frame(region: picture,textSize: CGSize(width: 200,height: 35),margin: NativeCaptionLayout.defaultMargin,controls: nil)
        XCTAssertEqual(video.maxY - frame.maxY,9.825,accuracy: 0.01)
    }

    func testChromeUsesLetterboxSpaceInPortraitAndScreenEdgeInLandscape() {
        let portraitViewport = CGRect(x: 0,y: 0,width: 402,height: 874)
        let portraitVideo = CGRect(x: 0,y: 286,width: 402,height: 302)
        let portraitInsets = UIEdgeInsets(top: 62,left: 0,bottom: 34,right: 0)
        let portrait = NativeChromeLayout.fitted(video: portraitVideo,viewport: portraitViewport,safeInsets: portraitInsets)
        XCTAssertEqual(portrait.transportCenter,CGPoint(x: portraitVideo.midX,y: portraitVideo.midY))
        XCTAssertEqual(portrait.header.maxY,portraitVideo.minY - 8)
        XCTAssertEqual(portrait.dock.minY,portraitVideo.maxY + 8)
        XCTAssertTrue(portraitViewport.inset(by: portraitInsets).contains(portrait.header))
        XCTAssertTrue(portraitViewport.inset(by: portraitInsets).contains(portrait.dock))
        let landscapeViewport = CGRect(x: 0,y: 0,width: 852,height: 393)
        let landscapeVideo = CGRect(x: 164,y: 0,width: 524,height: 393)
        let landscapeInsets = UIEdgeInsets(top: 0,left: 59,bottom: 21,right: 59)
        let landscape = NativeChromeLayout.fitted(video: landscapeVideo,viewport: landscapeViewport,safeInsets: landscapeInsets,dockHeight: 88)
        let image = landscapeVideo.intersection(landscapeViewport.inset(by: landscapeInsets))
        XCTAssertTrue(image.contains(landscape.header)); XCTAssertTrue(image.contains(landscape.dock))
        XCTAssertEqual(landscape.transportCenter,CGPoint(x: image.midX,y: image.midY))
        XCTAssertEqual(landscape.dock.midX,image.midX)
        XCTAssertEqual(landscape.dock.width,0.70 * landscapeViewport.inset(by: landscapeInsets).width,accuracy: 0.1)
        XCTAssertEqual(landscape.dock.maxY,landscapeViewport.maxY - landscapeInsets.bottom - 8)
        let withCaptions = NativeChromeLayout.fitted(video: landscapeVideo,viewport: landscapeViewport,safeInsets: landscapeInsets,dockHeight: 88,captionLane: 80)
        XCTAssertEqual(withCaptions.dock,landscape.dock)
        XCTAssertEqual(landscape.header.width,landscape.dock.width)
        let caption = NativeCaptionLayout.frame(region: image,textSize: CGSize(width: 300,height: 70),margin: 0.1,
                                                controls: landscape.dock,header: landscape.header)
        XCTAssertLessThanOrEqual(caption.maxY,landscape.dock.minY - 12,"The actual drawn dock rectangle must also exclude selectable captions after rotation and measured-height changes")
        XCTAssertTrue(image.contains(caption))
        let loading = NativeChromeLayout.fitted(video: .zero,viewport: portraitViewport,safeInsets: portraitInsets)
        XCTAssertTrue(portraitViewport.inset(by: portraitInsets).contains(loading.header))
        XCTAssertTrue(portraitViewport.inset(by: portraitInsets).contains(loading.dock))
        let actualSafe = NativeSafeArea.viewport(bounds: portraitViewport,localInsets: .zero,windowSafe: portraitViewport.inset(by: portraitInsets))
        let ignoredSwiftUIInsets = NativeChromeLayout.fitted(video: .zero,viewport: portraitViewport,safeInsets: .zero,safeViewport: actualSafe)
        XCTAssertTrue(actualSafe.contains(ignoredSwiftUIInsets.header),"An ignoresSafeArea GeometryReader must not place loading actions under the Dynamic Island")
        XCTAssertGreaterThanOrEqual(ignoredSwiftUIInsets.header.minY,62)
        XCTAssertLessThanOrEqual(ignoredSwiftUIInsets.dock.maxY,840,"Keep the Home indicator clear even before video bounds arrive")
        let offsetHost = NativeSafeArea.viewport(bounds: CGRect(x: 0,y: 0,width: 382,height: 834),localInsets: .zero,
                                                windowSafe: CGRect(x: -10,y: 42,width: 402,height: 778))
        XCTAssertEqual(offsetHost,CGRect(x: 0,y: 42,width: 382,height: 778),"Window safe coordinates must be intersected in the owning host's coordinates, without padding twice")
    }

    func testVideoGeometryCoalescesChangedBoundsAndDoesNotRepublishIdenticalLayouts() async {
        let geometry = NativeVideoGeometry(), final = CGRect(x: 164,y: 0,width: 524,height: 372)
        let safe = CGRect(x: 59,y: 0,width: 734,height: 372)
        let published = expectation(description: "latest real video rectangle")
        var values: [CGRect] = []
        let observation = geometry.$snapshot.dropFirst().sink { value in values.append(value.region); if values.count == 1 { published.fulfill() } }
        defer { observation.cancel() }
        geometry.report(CGRect(x: 0,y: 286,width: 402,height: 302)); geometry.report(final,safeViewport: safe)
        await fulfillment(of: [published],timeout: 2)
        XCTAssertEqual(geometry.region,final); XCTAssertEqual(geometry.safeViewport,safe); XCTAssertEqual(values,[final])
        for _ in 0..<100 { geometry.report(final,safeViewport: safe) }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(values,[final],"Unchanged caption/chrome layout cannot create a geometry feedback cycle")
        let changedSafe = safe.insetBy(dx: 0,dy: 10), changed = expectation(description: "safe area changed without a video-bounds change")
        let safeObservation = geometry.$snapshot.filter { $0.safeViewport == changedSafe }.first().sink { _ in changed.fulfill() }
        defer { safeObservation.cancel() }
        geometry.report(final,safeViewport: changedSafe)
        await fulfillment(of: [changed],timeout: 2)
        XCTAssertEqual(geometry.region,final); XCTAssertEqual(values.count,2)
    }

    func testShortcutsSitFlushAboveTheDockWhileTheTimedSkipCanStandAlone() {
        for viewport in [CGRect(x: 0,y: 0,width: 402,height: 874),CGRect(x: 0,y: 0,width: 852,height: 393)] {
            let portrait = viewport.width < viewport.height
            let video = portrait ? CGRect(x: 0,y: 310,width: 402,height: 254) : CGRect(x: 164,y: 0,width: 524,height: 393)
            let hidden = NativeChromeLayout.fitted(video: video,viewport: viewport,safeInsets: .zero,captionLane: 52)
            let shown = NativeChromeLayout.fitted(video: video,viewport: viewport,safeInsets: .zero,captionLane: 52,controlsVisible: true)
            XCTAssertEqual(hidden.shortcuts.maxX,video.maxX - 8)
            XCTAssertEqual(hidden.shortcuts.maxY,video.maxY - 52)
            XCTAssertEqual(shown.shortcuts.maxX,shown.dock.maxX)
            XCTAssertEqual(shown.shortcuts.maxY,shown.dock.minY)
            XCTAssertEqual(shown.shortcuts.height,44)
            if portrait { XCTAssertEqual(shown.shortcuts.minY,video.maxY + 8) }
            else {
                let exclusion = shown.dock.union(shown.shortcuts)
                let caption = NativeCaptionLayout.available(region: video,margin: 0.03,controls: exclusion,preferAboveControls: true)
                XCTAssertLessThan(caption.maxY,shown.shortcuts.minY)
            }
        }
    }

    func testUnifiedPlayerDisablesCompetingNativeChromeAndHasNoCaptionBackdrop() throws {
        let host = NativeVideoHostController(); host.loadViewIfNeeded()
        XCTAssertFalse(host.playback.showsPlaybackControls)
        XCTAssertFalse(host.playback.allowsVideoFrameAnalysis)
        XCTAssertFalse(host.playback.allowsPictureInPicturePlayback)
        XCTAssertTrue(host.prefersStatusBarHidden)
        XCTAssertEqual(host.caption.backgroundColor,UIColor.clear)
        XCTAssertEqual(host.caption.numberOfLines,0)
        XCTAssertFalse(host.caption.isUserInteractionEnabled)
        XCTAssertEqual(host.caption.accessibilityIdentifier,"player.caption")
        for size in [CGFloat(18),CGFloat(32)] {
            let label = NativeOutlinedCaptionLabel()
            label.backgroundColor = .clear; label.numberOfLines = 0
            label.attributedText = NativeCaptionStyle.text("Ship off the\nstarboard stern!",size: size)
            let font = try XCTUnwrap(label.attributedText?.attribute(.font,at: 0,effectiveRange: nil) as? UIFont)
            XCTAssertEqual(font.fontName,"Roboto-Bold","The app must actually load its shared bundled face")
            XCTAssertNil(label.attributedText?.attribute(.shadow,at: 0,effectiveRange: nil))
            label.contentPadding = NativeCaptionStyle.padding(size: size)
            label.outlineRadius = NativeCaptionStyle.outlineRadius(size: size)
            label.frame = CGRect(origin: .zero,size: label.sizeThatFits(CGSize(width: 280,height: 500)))
            label.layer.contentsScale = 1; label.setNeedsLayout(); label.layoutIfNeeded()
            label.setNeedsDisplay(); label.layer.displayIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            let image = UIGraphicsImageRenderer(size: label.bounds.size,format: format).image { context in label.layer.render(in: context.cgContext) }
            let cgImage = try XCTUnwrap(image.cgImage), width = cgImage.width, height = cgImage.height
            var pixels = [UInt8](repeating: 0,count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage,in: CGRect(x: 0,y: 0,width: CGFloat(width),height: CGFloat(height)))
            var white = 0, black = 0, edgeInk = 0
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4, alpha = pixels[offset + 3]
                if alpha > 245 && pixels[offset] > 245 && pixels[offset + 1] > 245 && pixels[offset + 2] > 245 { white += 1 }
                if alpha > 245 && pixels[offset] < 10 && pixels[offset + 1] < 10 && pixels[offset + 2] < 10 { black += 1 }
                if (x == 0 || y == 0 || x == width - 1 || y == height - 1) && alpha != 0 { edgeInk += 1 }
            } }
            XCTAssertGreaterThan(white,20,"Two-pass rendering must preserve solid white glyph interiors")
            XCTAssertGreaterThan(black,20,"The outline must draw actual opaque black pixels")
            XCTAssertEqual(edgeInk,0,"Outline and multiline glyphs must fit with transparent, unclipped outer padding")
        }
    }

    func testEmbeddedCaptionsStayTransparentOutlinedWithSavedOriginalFontPreference() throws {
        let http = PlaybackHTTP(), model = try make(http,fixture: true)
        model.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        model.applyStyles()
        let attributes = try XCTUnwrap(model.player.currentItem?.textStyleRules?.first?.textMarkupAttributes)
        for key in [kCMTextMarkupAttribute_BackgroundColorARGB,kCMTextMarkupAttribute_CharacterBackgroundColorARGB] {
            XCTAssertEqual((attributes[key as String] as? [NSNumber])?.map(\.doubleValue),[0,0,0,0])
        }
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,kCMTextMarkupCharacterEdgeStyle_Uniform as String)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_FontFamilyName as String] as? String,"Roboto")
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_BoldStyle as String] as? Bool,true)
        let item = try XCTUnwrap(model.player.currentItem)
        model.installEmbeddedCaptionOutput(on: item)
        let output = try XCTUnwrap(item.outputs.first as? AVPlayerItemLegibleOutput)
        XCTAssertTrue(output.suppressesPlayerRendering)
        output.delegate?.legibleOutput?(output,didOutputAttributedStrings: [
            NSAttributedString(string: "Embedded dialogue"),
            NSAttributedString(string: "https://example.test/preview.jpg#xywh=0,0,160,90")
        ],nativeSampleBuffers: [],forItemTime: .zero)
        XCTAssertEqual(model.captionText,"Embedded dialogue")
        output.delegate?.outputSequenceWasFlushed?(output)
        XCTAssertEqual(model.captionText,"")
        model.originalStyles = true
        let originalFont = try XCTUnwrap(model.player.currentItem?.textStyleRules?.first?.textMarkupAttributes)
        for key in [kCMTextMarkupAttribute_BackgroundColorARGB,kCMTextMarkupAttribute_CharacterBackgroundColorARGB] {
            XCTAssertEqual((originalFont[key as String] as? [NSNumber])?.map(\.doubleValue),[0,0,0,0],"A saved original-style preference cannot restore a black caption box")
        }
        XCTAssertEqual(originalFont[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,kCMTextMarkupCharacterEdgeStyle_Uniform as String)
        XCTAssertEqual((originalFont[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [NSNumber])?.map(\.doubleValue),[1,1,1,1])
        XCTAssertEqual((originalFont[kCMTextMarkupAttribute_RelativeFontSize as String] as? NSNumber)?.doubleValue,100)
        model.captionSize = 30
        XCTAssertEqual((model.player.currentItem?.textStyleRules?.first?.textMarkupAttributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? NSNumber)?.doubleValue,30.0 / 22 * 100)
        XCTAssertFalse(output.suppressesPlayerRendering,"Only explicit source placement uses the native renderer")
        XCTAssertNil(model.player.currentItem?.textStyleRules?.first?.textMarkupAttributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String])
    }

    func testExplicitPausedTimelineSeekClampsAndSurvivesFreshResumeWithoutAnEarlyClaim() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        var seeks: [Double] = []
        var currentPosition = 120.0, seekingStates: [Bool] = []
        let model = try make(http,clock: { (position: currentPosition,duration: 1000) },seek: { _,at in seeks.append(at); currentPosition = at })
        let observation = model.$isSeeking.dropFirst().sink { seekingStates.append($0) }
        defer { observation.cancel() }
        model.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition())); model.videoReady = true
        await model.seek(to: .nan); await model.seek(to: -.infinity)
        XCTAssertTrue(seeks.isEmpty)
        await model.seek(to: -10); await model.seek(to: 1200); await model.seek(to: 350)
        XCTAssertEqual(seeks,[0,1000,350]); XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(model.isSeeking)
        XCTAssertEqual(model.position,350)
        XCTAssertEqual(seekingStates,[true,false,true,false,true,false],"Paused dock updates are driven by each explicit seek, without a periodic animation tick")
        await model.play(explicit: true)
        XCTAssertEqual(seeks.last,350,"A deliberate paused timeline action must survive the fresh server resume checkpoint")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
    }

    func testManualNextUsesThePausedEpisodesGenerationWithoutCompletingIt() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let model = try make(http)
        model.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition())); model.videoReady = true
        let next = EpisodeChoice(id: "7",label: "7",number: "7",url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=7"))
        var requested: EpisodeChoice?, generation: Int64?
        model.onNextEpisode = { episode,fence in requested = episode; generation = fence }
        model.advanceEpisode()
        XCTAssertNil(requested)
        model.nextEpisode = next
        await model.play(explicit: true)
        await model.background()
        XCTAssertNil(model.lease)
        model.advanceEpisode()
        XCTAssertEqual(requested,next)
        XCTAssertEqual(generation,2)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
        let progress = http.requests.filter { $0.url?.path == "/api/progress" && $0.httpMethod == "POST" }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertTrue(try progress.allSatisfy { try object($0)["completed"] == .bool(false) })
    }

    func testBackgroundFencesAnInFlightCustomSeekAndPlayCannotRaceItsCompletion() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let blocked = gate("custom timeline seek in flight")
        var seeks: [Double] = []
        let model = try make(http,seek: { _,at in seeks.append(at); if seeks.count == 1 { await blocked.wait() } })
        model.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition())); model.videoReady = true
        let seek = Task { await model.seek(to: 350) }; tasks.append(seek)
        await fulfillment(of: [blocked.started],timeout: 2)
        XCTAssertTrue(model.isSeeking)
        await model.play(explicit: true); XCTAssertTrue(http.requests.isEmpty)
        await model.background(); XCTAssertFalse(model.isSeeking)
        await model.play(explicit: true)
        blocked.open(); await seek.value
        XCTAssertEqual(seeks,[350,120],"A backgrounded timeline checkpoint cannot override the fresh server checkpoint")
        XCTAssertGreaterThan(model.player.rate,0); XCTAssertFalse(model.isSeeking)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
    }

    func testLateEnglishSubtitleDiscoveryRendersAndCannotOverrideOff() async throws {
        let http = PlaybackHTTP(), captions = PlaybackHTTP()
        http.respond = { _ in XCTFail("Caption discovery may not claim/write playback"); return try self.reply([:]) }
        captions.respond = { _ in HTTPReply(status: 200,body: Data("WEBVTT\n\n00:01:59.000 --> 00:02:01.000\nLate English cue\n\n".utf8)) }
        let model = try make(http,captionTransport: captions)
        let french = SubtitleSource(url: URL(string: "https://cdn.example/caption?lang=fr")!,label: "French",language: "fr")
        let english = SubtitleSource(url: URL(string: "https://cdn.example/caption?lang=en")!,label: "English",language: "en")
        let blocked = SubtitleSource(url: URL(string: "https://10.0.0.10/private.vtt")!,label: "Blocked")
        let shown = expectation(description: "late extensionless English cue rendered")
        let observation = model.$captionText.filter { $0 == "Late English cue" }.first().sink { _ in shown.fulfill() }
        defer { observation.cancel() }
        model.updateSubtitles([blocked,french,english,english])
        await fulfillment(of: [shown],timeout: 3)
        XCTAssertEqual(model.subtitles,[french,english]); XCTAssertEqual(model.captionSelection,english.id)
        XCTAssertEqual(captions.requests.map(\.url),[english.url]); XCTAssertTrue(http.requests.isEmpty)
        model.selectSubtitle(nil)
        model.updateSubtitles([SubtitleSource(url: URL(string: "https://cdn.example/new.vtt")!,label: "New English",language: "en")])
        XCTAssertEqual(model.captionSelection,"off"); XCTAssertEqual(model.captionText,""); XCTAssertEqual(captions.requests.count,1)
    }

    func testAutomaticCaptionPolicyPrefersExternalEnglishOverUnlabeledCCWithoutOverridingIntent() {
        let french = SubtitleSource(url: URL(string: "https://cdn.example/fr.vtt")!,label: "French",language: "fr")
        let english = SubtitleSource(url: URL(string: "https://cdn.example/en.vtt")!,label: "English",language: "en")
        XCTAssertEqual(NativeCaptionPolicy.automaticExternal([french,english],embeddedLanguages: [""],automatic: true),english,"The real provider exposes an unlabeled CC option alongside external English")
        XCTAssertEqual(NativeCaptionPolicy.automaticExternal([french,english],embeddedLanguages: ["ja"],automatic: true),english)
        XCTAssertNil(NativeCaptionPolicy.automaticExternal([english],embeddedLanguages: ["en-US"],automatic: true),"Known embedded English remains preferred")
        XCTAssertNil(NativeCaptionPolicy.automaticExternal([english],embeddedLanguages: [""],automatic: false),"Off and explicit embedded/external selections suppress automatic changes")
        XCTAssertNil(NativeCaptionPolicy.automaticExternal([french],embeddedLanguages: [""],automatic: true))
        XCTAssertEqual(NativeCaptionPolicy.automaticExternal([french],embeddedLanguages: [],automatic: true),french)
    }

    func testAutomaticSubtitleRequestRepairsChangedHeadersAtSameURLWithoutRepeatingUnchangedRequests() async throws {
        let http = PlaybackHTTP(), captions = PlaybackHTTP(), early = gate("early generic subtitle request"), repaired = gate("corrected subtitle request")
        http.respond = { _ in XCTFail("Subtitle header repair must not contact Sync"); return try self.reply([:]) }
        let url = URL(string: "https://cdn.example/extensionless-caption?id=en")!
        let generic = SubtitleSource(url: url,label: "English",language: "en",headers: ["Referer":"https://miruro.cx/"])
        let configured = SubtitleSource(url: url,label: "English",language: "en",headers: ["Referer":"https://player.example/embed/episode","Origin":"https://player.example"],configured: true)
        let vtt = Data("WEBVTT\n\n00:01:59.000 --> 00:02:01.000\nRepaired cue\n\n".utf8)
        captions.respond = { [weak captions] request in
            let count = captions?.requests.count ?? 0
            if count == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),"https://miruro.cx/")
                await early.wait(); return HTTPReply(status: 403,body: Data())
            }
            XCTAssertEqual(count,2,"An unchanged request identity must not issue another GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),"https://player.example/embed/episode")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"),"https://player.example")
            if count == 2 { await repaired.wait() }
            return HTTPReply(status: 200,body: vtt)
        }
        let model = try make(http,captionTransport: captions)
        model.updateSubtitles([generic])
        await fulfillment(of: [early.started],timeout: 3)
        model.updateSubtitles([configured])
        await fulfillment(of: [repaired.started],timeout: 3)
        var relabeled = configured; relabeled.label = "English subtitles"
        model.updateSubtitles([configured]); model.updateSubtitles([relabeled])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(captions.requests.count,2)
        early.open(); for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(model.message.contains("could not load"),"A late canceled403 must not overwrite the repaired request")
        let shown = expectation(description: "corrected same-URL captions rendered")
        let observation = model.$captionText.filter { $0 == "Repaired cue" }.first().sink { _ in shown.fulfill() }
        defer { observation.cancel() }
        repaired.open(); await fulfillment(of: [shown],timeout: 3)
        model.updateSubtitles([configured]); for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(model.captionText,"Repaired cue"); XCTAssertEqual(captions.requests.count,2); XCTAssertTrue(http.requests.isEmpty)
    }

    func testLateSubtitleListsPreserveExplicitChoicesAndIgnoreClosedPlayers() async throws {
        let http = PlaybackHTTP(), captions = PlaybackHTTP()
        http.respond = { _ in XCTFail("Caption discovery may not contact Sync"); return try self.reply([:]) }
        captions.respond = { _ in HTTPReply(status: 200,body: Data("WEBVTT\n\n00:01:59.000 --> 00:02:01.000\nChosen cue\n\n".utf8)) }
        let model = try make(http,captionTransport: captions)
        let chosen = SubtitleSource(url: URL(string: "https://cdn.example/chosen.vtt")!,label: "Chosen")
        let late = SubtitleSource(url: URL(string: "https://cdn.example/late.vtt")!,label: "Late English",language: "en")
        let shown = expectation(description: "explicit caption loaded")
        let observation = model.$captionText.filter { $0 == "Chosen cue" }.first().sink { _ in shown.fulfill() }
        defer { observation.cancel() }
        model.selectSubtitle(chosen)
        await fulfillment(of: [shown],timeout: 3)
        model.updateSubtitles([late])
        XCTAssertEqual(model.captionSelection,chosen.id); XCTAssertEqual(model.captionText,"Chosen cue")
        model.selectEmbedded(nil); model.updateSubtitles([chosen,late])
        XCTAssertEqual(model.captionSelection,"off"); XCTAssertEqual(captions.requests.count,1)
        let beforeClose = model.subtitles
        await model.close(); model.updateSubtitles([])
        XCTAssertEqual(model.subtitles,beforeClose); XCTAssertEqual(captions.requests.count,1); XCTAssertTrue(http.requests.isEmpty)
    }

    func testLatePausedSaveRetainsTheSessionWhenPlayResumed() async throws {
        let http = PlaybackHTTP(), blockedSave = gate("paused save reached transport")
        http.respond = { request in
            if request.url?.path == "/api/progress", request.httpMethod == "POST" { await blockedSave.wait() }
            return try self.defaultResponse(request)
        }
        let model = try make(http)
        await model.play(explicit: true)
        let lease = try XCTUnwrap(model.lease)
        XCTAssertGreaterThan(model.player.rate, 0, "AVPlayer must hold the actual play intent for this lifecycle fixture")
        model.pause()
        await fulfillment(of: [blockedSave.started],timeout: 3)
        model.player.play()
        blockedSave.open()
        await model.sync.flushPending()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertGreaterThan(model.player.rate, 0)
        XCTAssertTrue(model.lease === lease, "Late pause acknowledgement cannot release the resumed session")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
    }

    func testBackgroundSaveCannotReleaseAResumedNativePlayIntent() async throws {
        let http = PlaybackHTTP(), blockedSave = gate("background save reached transport")
        http.respond = { request in
            if request.url?.path == "/api/progress", request.httpMethod == "POST" { await blockedSave.wait() }
            return try self.defaultResponse(request)
        }
        let model = try make(http)
        await model.play(explicit: true)
        let lease = try XCTUnwrap(model.lease)
        let background = Task { await model.background() }; tasks.append(background)
        await fulfillment(of: [blockedSave.started],timeout: 3)
        // The user can press AVPlayer's own Play while the app returns and its
        // outgoing checkpoint is still awaiting an acknowledgement.
        model.player.play()
        for _ in 0..<8 { await Task.yield() }
        blockedSave.open(); await background.value
        await model.sync.flushPending()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertGreaterThan(model.player.rate,0)
        XCTAssertTrue(model.lease === lease, "An older background save cannot release a resumed native Play intent")
    }

    func testClosingRejectsPlayWhileTheFinalSaveIsPending() async throws {
        let http = PlaybackHTTP(), blockedSave = gate("closing save reached transport")
        http.respond = { request in
            if request.url?.path == "/api/progress", request.httpMethod == "POST" { await blockedSave.wait() }
            return try self.defaultResponse(request)
        }
        let model = try make(http)
        await model.play(explicit: true)
        let close = Task { await model.close() }; tasks.append(close)
        await fulfillment(of: [blockedSave.started],timeout: 3)
        await model.play(explicit: true)
        model.player.play()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(model.player.rate,0,"Closing must also suppress native-control Play")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
        blockedSave.open(); await close.value
        XCTAssertNil(model.lease)
        XCTAssertNil(model.player.currentItem)
    }

    func testOldStartCompletionCannotClearNewerStartingIntent() async throws {
        let http = PlaybackHTTP(), oldHead = gate("old head in flight"), newHead = gate("new head in flight")
        var reads = 0
        http.respond = { request in
            if request.httpMethod == "GET" {
                reads += 1
                if reads == 1 { await oldHead.wait() } else if reads == 2 { await newHead.wait() }
                return try self.reply(self.snapshot(reads == 1 ? 1 : 2))
            }
            if request.url?.path == "/api/playback" {
                let generation = try XCTUnwrap(self.object(request)["expected_generation"]?.integer)
                return try self.reply(self.snapshot(generation + 1))
            }
            return try self.reply(["ok": .bool(true)])
        }
        let model = try make(http)
        let first = Task { await model.play(explicit: true) }; tasks.append(first)
        await fulfillment(of: [oldHead.started],timeout: 3)
        await model.background()
        let second = Task { await model.play(explicit: true) }; tasks.append(second)
        await Task.yield(); oldHead.open()
        await fulfillment(of: [newHead.started],timeout: 3)
        await first.value
        XCTAssertTrue(model.isStarting, "Stale completion must not clear the newer request's loading gate")
        XCTAssertNil(model.lease)
        XCTAssertFalse(http.requests.contains { $0.url?.path == "/api/playback" },"Background cancellation must stop the stale head read before it claims")
        newHead.open(); await second.value
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(model.lease?.generation,3)
    }

    func testLocalOnlyForegroundDoesNotClaimTheNewRemoteHead() async throws {
        let http = PlaybackHTTP()
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        let model = try make(http)
        await model.play(explicit: true)
        XCTAssertNil(model.lease); XCTAssertGreaterThan(model.player.rate,0)
        await model.background()
        let before = http.requests.count
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(8,session: "pc-newer-session")) }
            return try self.reply(self.snapshot(9))
        }
        await model.foreground()
        XCTAssertEqual(http.requests.count,before, "Automatic unowned foreground may not fetch-and-claim")
        XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.lease)
        await model.play(explicit: true)
        XCTAssertEqual(model.lease?.generation,9, "A later real Play may acquire the fresh remote generation")
    }

    func testOwnedForegroundRejectsAnAdvancedGeneration() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let model = try make(http)
        await model.play(explicit: true); XCTAssertEqual(model.lease?.generation,2)
        let priorLease = try XCTUnwrap(model.lease)
        await model.background()
        let claimsBefore = http.requests.filter { $0.url?.path == "/api/playback" }.count
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(3,session: "pc-newer-session")) }
            if request.httpMethod == "POST", request.url?.path == "/api/progress" {
                // A delayed pause-KVO checkpoint may still be drained when begin
                // flushes its durable queue. It must retain the OLD lease and be
                // rejected by the advanced server, never be relabelled/accepted.
                let body = try self.object(request)
                XCTAssertEqual(body["playback_session_id"]?.string,priorLease.id)
                XCTAssertEqual(body["playback_generation"]?.integer,2)
                XCTAssertEqual(body["sync_protocol"]?.integer,2)
                return try self.reply(["error": .string("Playback continued on PC")],status: 409)
            }
            XCTFail("Stale automatic restore sent unexpected \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
            return try self.reply(["error": .string("Unexpected mutation")],status: 409)
        }
        await model.foreground()
        XCTAssertNil(model.lease); XCTAssertEqual(model.player.rate,0)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,claimsBefore)
    }

    func testDuplicateBackgroundCallbacksKeepTheOwnedForegroundGeneration() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let model = try make(http)
        await model.play(explicit: true); await model.background(); await model.background()
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/progress" && $0.httpMethod == "POST" }.count,1)
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(2,session: "previous-iphone-session")) }
            if request.url?.path == "/api/playback" {
                XCTAssertEqual(try self.object(request)["expected_generation"]?.integer,2)
                return try self.reply(self.snapshot(3))
            }
            return try self.reply(["ok": .bool(true)])
        }
        await model.foreground()
        XCTAssertEqual(model.lease?.generation,3); XCTAssertGreaterThan(model.player.rate,0)
    }

    func testOwnedForegroundResolvesFreshSourceBeforeRebuildingAtTheSavedCheckpoint() async throws {
        let http = PlaybackHTTP(), asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        let fresh = MediaSource(url: URL(string: "https://example.invalid/fresh.mp4")!)
        let checkpoint = 317.25
        var savedPosition: TimeInterval = 120, position: TimeInterval = 0
        var generation: Int64 = 1
        var saved: [JSONObject] = [], refreshed: [URL] = [], itemSources: [URL] = []
        var seeks: [TimeInterval] = [], playbackSteps: [String] = []
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(generation,position: savedPosition)) }
            let body = try self.object(request)
            if request.url?.path == "/api/playback" {
                XCTAssertEqual(body["expected_generation"]?.integer,generation)
                generation += 1
                return try self.reply(self.snapshot(generation,position: savedPosition))
            }
            if request.url?.path == "/api/progress" {
                saved.append(body)
                savedPosition = try XCTUnwrap(body["current_time"]?.double)
            }
            return try self.reply(["ok": .bool(true)])
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            playbackSteps.append("seek"); seeks.append(target); position = target
        },itemFactory: { source in
            playbackSteps.append("item"); itemSources.append(source.url)
            return AVPlayerItem(url: asset)
        })
        let originalSource = model.source.url
        model.refreshSource = { source in
            playbackSteps.append("refresh"); refreshed.append(source.url)
            return (fresh,[])
        }
        await model.play(explicit: true)
        let oldItem = try XCTUnwrap(model.player.currentItem)
        let oldLease = try XCTUnwrap(model.lease)
        XCTAssertEqual(oldLease.generation,2)
        position = checkpoint
        // The system can pause AVPlayer before the scene reports background.
        model.player.pause()

        await model.background(); await model.background()
        await model.foreground(); await model.foreground()

        XCTAssertEqual(playbackSteps,["item","seek","refresh","item","seek"])
        XCTAssertEqual(refreshed,[originalSource]); XCTAssertEqual(itemSources,[originalSource,fresh.url])
        XCTAssertFalse(model.player.currentItem === oldItem)
        XCTAssertEqual(seeks,[120,checkpoint]); XCTAssertEqual(model.lease?.generation,3)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,2)
        XCTAssertEqual(saved.count,1,"One interruption must save the outgoing checkpoint only once")
        let payload = try XCTUnwrap(saved.first)
        XCTAssertEqual(payload["current_time"]?.double,checkpoint)
        XCTAssertEqual(payload["duration"]?.double,1000)
        XCTAssertEqual(payload["completed"]?.bool,false)
        XCTAssertEqual(payload["anime_id"]?.string,metadata.animeID)
        XCTAssertEqual(payload["episode"]?.string,metadata.episode)
        XCTAssertEqual(payload["playback_session_id"]?.string,oldLease.id)
        XCTAssertEqual(payload["playback_generation"]?.integer,oldLease.generation)
        XCTAssertEqual(payload["playback_sequence"]?.integer,1)
        await model.close()
    }

    func testReconnectingNearTheEndKeepsTheCheckpointWhileAFreshReplayStartsAtZero() async throws {
        let http = PlaybackHTTP()
        var generation: Int64 = 1
        var savedPosition: TimeInterval = 120, position: TimeInterval = 0
        var completed = false
        var seeks: [TimeInterval] = []
        http.respond = { request in
            if request.url?.path == "/api/playback" { generation += 1 }
            if request.httpMethod == "POST", request.url?.path == "/api/progress" {
                let body = try self.object(request)
                savedPosition = try XCTUnwrap(body["current_time"]?.double)
                completed = try XCTUnwrap(body["completed"]?.bool)
            }
            return try self.reply(self.snapshot(generation,position: savedPosition,completed: completed))
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target)
            position = target
        })
        await model.play(explicit: true)
        position = 950
        await model.background()
        XCTAssertEqual(savedPosition,950)
        XCTAssertTrue(completed,"A partially played ending is marked watched for the library")
        await model.foreground()
        XCTAssertEqual(seeks,[120,950])
        await model.close()
        XCTAssertEqual(savedPosition,950)

        let replay = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target)
            position = target
        })
        await replay.play(explicit: true)
        XCTAssertEqual(seeks,[120,950,0],"Opening a new player can intentionally replay a watched episode")
    }

    func testSameOwnerReconnectWaitsForAnUnsentRewindBeforeClaiming() async throws {
        let http = PlaybackHTTP(), asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        var generation: Int64 = 1
        var position: TimeInterval = 0, savedPosition: TimeInterval = 600
        var allowProgress = false
        var writes: [TimeInterval] = [], seeks: [TimeInterval] = []
        http.respond = { request in
            if request.url?.path == "/api/playback" { generation += 1 }
            if request.httpMethod == "POST", request.url?.path == "/api/progress" {
                let body = try self.object(request)
                let at = try XCTUnwrap(body["current_time"]?.double)
                XCTAssertEqual(body["playback_generation"]?.integer,2)
                writes.append(at)
                guard allowProgress else { throw URLError(.networkConnectionLost) }
                savedPosition = at
            }
            return try self.reply(self.snapshot(generation,position: savedPosition))
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target)
            position = target
        },itemFactory: { _ in AVPlayerItem(url: asset) })
        model.refreshSource = { ($0,[]) }
        await model.play(explicit: true)
        model.videoReady = true
        await model.seek(to: 240)
        await model.background()
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { $0 == 240 })
        await model.foreground()
        XCTAssertNil(model.lease)
        XCTAssertEqual(generation,2,"A reachable claim endpoint must not supersede the unacknowledged save")
        XCTAssertEqual(seeks,[600,240])
        await model.play(explicit: true)
        XCTAssertNil(model.lease)
        XCTAssertEqual(generation,2)
        allowProgress = true
        await model.play(explicit: true)
        XCTAssertEqual(savedPosition,240)
        XCTAssertEqual(model.lease?.generation,3)
        XCTAssertEqual(seeks,[600,240,240],"A confirmed rewind must survive an interrupted final save")
        http.respond = { _ in try self.reply(["ok": .bool(true)]) }
    }

    func testManualReconnectUsesTheNewOwnerPositionEvenWhenMarkedWatched() async throws {
        let http = PlaybackHTTP()
        var generation: Int64 = 1
        var savedPosition: TimeInterval = 120, position: TimeInterval = 0
        var completed = false
        var seeks: [TimeInterval] = []
        http.respond = { request in
            if request.url?.path == "/api/playback" { generation += 1 }
            if request.httpMethod == "POST", request.url?.path == "/api/progress" {
                savedPosition = try XCTUnwrap(self.object(request)["current_time"]?.double)
            }
            return try self.reply(self.snapshot(generation,position: savedPosition,completed: completed))
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target)
            position = target
        })
        await model.play(explicit: true)
        position = 995
        await model.background()
        generation = 8
        savedPosition = 930
        completed = true
        await model.foreground()
        XCTAssertEqual(seeks,[120])
        XCTAssertNil(model.lease)
        XCTAssertEqual(generation,8)

        await model.play(explicit: true)
        XCTAssertEqual(seeks,[120,930],"After a takeover the newer owner's saved position wins, including a rewind")
        XCTAssertEqual(model.lease?.generation,9)
    }

    func testReconnectCannotSaveZeroWhileTheNewItemsClockSettles() async throws {
        let http = PlaybackHTTP(), asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        var generation: Int64 = 1
        var position: TimeInterval = 0, savedPosition: TimeInterval = 120
        var writes: [TimeInterval] = [], seeks: [TimeInterval] = []
        http.respond = { request in
            if request.url?.path == "/api/playback" { generation += 1 }
            if request.httpMethod == "POST", request.url?.path == "/api/progress" {
                savedPosition = try XCTUnwrap(self.object(request)["current_time"]?.double)
                writes.append(savedPosition)
            }
            return try self.reply(self.snapshot(generation,position: savedPosition))
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target)
            position = seeks.count == 1 ? target : 0
        },itemFactory: { _ in AVPlayerItem(url: asset) })
        model.refreshSource = { ($0,[]) }
        await model.play(explicit: true)
        position = 250
        await model.background()
        await model.foreground()
        XCTAssertEqual(seeks,[120,250])
        await model.save()
        XCTAssertEqual(writes,[250],"A new item's zero clock must not replace the checkpoint")
        position = 251
        await model.save()
        XCTAssertEqual(writes,[250,251],"The positioned item can continue syncing normally")
    }

    func testRetryOfInterruptedFirstStartCanBeginWithoutAProgressRow() async throws {
        let http = PlaybackHTTP(), seekGate = gate("first seek is interrupted")
        var generation: Int64 = 0
        var seeks: [Double] = []
        http.respond = { request in
            if request.url?.path == "/api/playback" { generation += 1 }
            return try self.reply(["sync": .object(["generation": .integer(generation)]),"progress": .null])
        }
        let model = try make(http,clock: { (position: 0,duration: 1000) },seek: { _, time in
            seeks.append(time)
            if seeks.count == 1 { await seekGate.wait() }
        })
        let first = Task { await model.play(explicit: true) }; tasks.append(first)
        await fulfillment(of: [seekGate.started],timeout: 2)
        await model.background()
        seekGate.open(); await first.value
        XCTAssertNil(model.lease)
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/progress" })

        await model.play(explicit: true)
        XCTAssertEqual(model.lease?.generation,2)
        XCTAssertEqual(seeks,[0,0],"A startup interrupted before any clock sample must still be able to play a new episode")
    }

    func testManualPauseSurvivesForegroundAndTheNextPlayResolvesFreshSource() async throws {
        let http = PlaybackHTTP(), asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        let fresh = MediaSource(url: URL(string: "https://example.invalid/fresh-after-pause.mp4")!)
        let checkpoint = 317.25
        var itemSources: [URL] = [], refreshed: [URL] = [], seeks: [TimeInterval] = []
        var position: TimeInterval = 0
        var generation: Int64 = 1
        var savedPosition: TimeInterval = 120
        let pausedSave = gate("Manual pause save is awaiting acknowledgement")
        let locking = expectation(description: "Background starts before the pause save is acknowledged")
        var progressWrites = 0
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(generation,position: savedPosition)) }
            let body = try self.object(request)
            if request.url?.path == "/api/playback" {
                XCTAssertEqual(body["expected_generation"]?.integer,generation)
                generation += 1
                return try self.reply(self.snapshot(generation,position: savedPosition))
            }
            if request.url?.path == "/api/progress" {
                savedPosition = try XCTUnwrap(body["current_time"]?.double)
                progressWrites += 1
                if progressWrites == 1 { await pausedSave.wait() }
            }
            return try self.reply(["ok": .bool(true)])
        }
        let model = try make(http,clock: { (position,1000) },seek: { _, target in
            seeks.append(target); position = target
        },itemFactory: { source in
            itemSources.append(source.url)
            return AVPlayerItem(url: asset)
        })
        let originalSource = model.source.url
        model.refreshSource = { source in refreshed.append(source.url); return (fresh,[]) }
        await model.play(explicit: true)
        let oldItem = try XCTUnwrap(model.player.currentItem)
        position = checkpoint
        model.pause()
        await fulfillment(of: [pausedSave.started],timeout: 3)
        let background = Task { locking.fulfill(); await model.background() }; tasks.append(background)
        await fulfillment(of: [locking],timeout: 3)
        pausedSave.open(); await background.value
        await model.sync.flushPending(); await model.foreground()

        XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.lease)
        XCTAssertTrue(model.player.currentItem === oldItem)
        XCTAssertTrue(refreshed.isEmpty); XCTAssertEqual(seeks,[120]); XCTAssertEqual(itemSources,[originalSource])
        XCTAssertEqual(progressWrites,1,"Lock must reuse the pending checkpoint from the manual pause")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)

        await model.play(explicit: true)
        XCTAssertEqual(refreshed,[originalSource]); XCTAssertEqual(itemSources,[originalSource,fresh.url])
        XCTAssertEqual(seeks,[120,checkpoint]); XCTAssertEqual(model.lease?.generation,3)
        XCTAssertEqual(progressWrites,1,"The replacement item must not write its initial position")
        await model.close()
    }

    func testOwnedForegroundNetworkFailureWaitsForExplicitFreshPlay() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        var seeks: [Double] = [], position = 120.0
        let model = try make(http,clock: { (position: position,duration: 1000) },seek: { _,at in seeks.append(at); position = at })
        await model.play(explicit: true)
        let previousLease = try XCTUnwrap(model.lease)
        position = 250
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        await model.background(); await model.foreground()
        XCTAssertEqual(seeks,[120]); XCTAssertNil(model.lease); XCTAssertEqual(model.player.rate,0)
        XCTAssertFalse(model.isStarting)
        var retriedOldCheckpoint = false
        http.respond = { request in
            if request.url?.path == "/api/progress", request.httpMethod == "POST" {
                let payload = try self.object(request)
                XCTAssertEqual(payload["current_time"]?.double,250)
                XCTAssertEqual(payload["playback_session_id"]?.string,previousLease.id)
                XCTAssertEqual(payload["playback_generation"]?.integer,2)
                retriedOldCheckpoint = true
                return try self.reply(["error": .string("Playback advanced on PC")],status: 409)
            }
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(8,session: "new-pc",position: 460)) }
            if request.url?.path == "/api/playback" {
                XCTAssertEqual(try self.object(request)["expected_generation"]?.integer,8)
                return try self.reply(self.snapshot(9,position: 460))
            }
            return try self.reply(["ok": .bool(true)])
        }
        await model.play(explicit: true)
        XCTAssertTrue(retriedOldCheckpoint)
        XCTAssertEqual(seeks,[120,460]); XCTAssertEqual(model.lease?.generation,9)
        // Remove the old-session-only response before teardown saves this new lease.
        http.respond = { try self.defaultResponse($0) }
    }

    func testInitialContinueWithCapturedGenerationDoesNotStartOfflineAtZero() async throws {
        let http = PlaybackHTTP(); http.respond = { _ in throw URLError(.notConnectedToInternet) }
        var seeks: [Double] = []
        let model = try make(http,generation: 8,clock: { (position: 0,duration: 1000) },seek: { _,at in seeks.append(at) })
        await model.prepare()
        XCTAssertTrue(seeks.isEmpty); XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.lease)
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(http.requests.map(\.httpMethod),["GET"])
    }

    func testSignedOutInitialGenerationZeroStillAllowsLocalPlayback() async throws {
        let http = PlaybackHTTP(); http.respond = { _ in throw URLError(.notConnectedToInternet) }
        var seeks: [Double] = []
        let model = try make(http,generation: 0,clock: { (position: 0,duration: 1000) },seek: { _,at in seeks.append(at) })
        try model.sync.signOut()
        await model.prepare()
        XCTAssertEqual(seeks,[0]); XCTAssertTrue(http.requests.isEmpty); XCTAssertNil(model.lease)
        XCTAssertGreaterThan(model.player.rate,0)
    }

    func testExplicitRetryCannotFallBackToZeroAfterAConfirmedCheckpoint() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        var seeks: [Double] = []
        var position = 120.0
        let model = try make(http,clock: { (position: position,duration: 1000) },seek: { _,at in seeks.append(at) })
        await model.play(explicit: true); await model.background()
        // A failed AVPlayerItem can report an invalid/zero time. That is not a
        // valid local fallback when this same episode has a known checkpoint.
        position = 0
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        await model.play(explicit: true)
        XCTAssertEqual(seeks,[120]); XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.lease)
        XCTAssertFalse(model.isStarting)
    }

    func testBackgroundDuringInitialSeekDoesNotSaveTheUnpositionedItem() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let blocked = gate("initial seek waiting after claim")
        let model = try make(http,clock: { (position: 0,duration: 1000) },seek: { _,_ in await blocked.wait() })
        let start = Task { await model.play(explicit: true) }; tasks.append(start)
        await fulfillment(of: [blocked.started],timeout: 2)
        XCTAssertEqual(model.lease?.generation,2)
        await model.background()
        XCTAssertFalse(model.isStarting); XCTAssertNil(model.lease)
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/progress" })
        blocked.open(); await start.value
        XCTAssertEqual(model.player.rate,0)
    }

    func testStartupSeekDeadlineReleasesControlsAndTheUnpositionedLease() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let blocked = gate("seek completion withheld"), returned = expectation(description: "Play returns before seek completes")
        let asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        let fresh = MediaSource(url: URL(string: "https://example.invalid/fresh-after-timeout.mp4")!)
        var seeks: [TimeInterval] = [], itemSources: [URL] = [], refreshed: [URL] = []
        let model = try make(http,seek: { _, target in
            seeks.append(target)
            if seeks.count == 1 { await blocked.wait() }
        },startupSeekTimeout: 0.1,itemFactory: { source in
            itemSources.append(source.url)
            return AVPlayerItem(url: asset)
        })
        let originalSource = model.source.url
        model.refreshSource = { source in refreshed.append(source.url); return (fresh,[]) }
        let start = Task { await model.play(explicit: true); returned.fulfill() }; tasks.append(start)
        await fulfillment(of: [blocked.started,returned],timeout: 2)
        XCTAssertFalse(model.isStarting); XCTAssertNil(model.lease); XCTAssertEqual(model.player.rate,0)
        XCTAssertTrue(model.message.contains("Press Play"))
        blocked.open(); await start.value
        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/progress" })

        await model.play(explicit: true)
        XCTAssertFalse(model.isStarting); XCTAssertNotNil(model.lease)
        XCTAssertEqual(refreshed,[originalSource]); XCTAssertEqual(itemSources,[originalSource,fresh.url])
        XCTAssertEqual(seeks,[120,120])
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/progress" })
        await model.close()
    }

    func testTerminalItemFailureRebuildsOnlyOnPlayAndUsesTheFreshCheckpoint() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let blocked = gate("first item's startup seek")
        // A local silent audio asset keeps the real AVPlayerItem alive without
        // requiring a codec fixture, network source or production account.
        let asset = try silentAudioAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        let fresh = MediaSource(url: URL(string: "https://example.invalid/fresh-after-failure.mp4")!)
        var items: [AVPlayerItem] = [], seeks: [Double] = []
        var itemSources: [URL] = [], refreshed: [URL] = []
        let model = try make(http,seek: { _,at in
            seeks.append(at)
            if seeks.count == 1 { await blocked.wait() }
        },itemFactory: { source in
            itemSources.append(source.url)
            let item = AVPlayerItem(url: asset)
            items.append(item); return item
        })
        let originalSource = model.source.url
        model.refreshSource = { source in refreshed.append(source.url); return (fresh,[]) }
        let first = Task { await model.play(explicit: true) }; tasks.append(first)
        await fulfillment(of: [blocked.started],timeout: 2)
        let failedItem = try XCTUnwrap(items.first)
        XCTAssertTrue(model.player.currentItem === failedItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,object: failedItem)
        XCTAssertFalse(model.isStarting); XCTAssertNil(model.lease)
        await model.foreground()
        XCTAssertEqual(items.count,1, "A failed item must not silently claim playback on foreground")
        XCTAssertTrue(refreshed.isEmpty)
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(8,session: "pc-advanced",position: 430)) }
            if request.url?.path == "/api/playback" {
                XCTAssertEqual(try self.object(request)["expected_generation"]?.integer,8)
                return try self.reply(self.snapshot(9,position: 430))
            }
            return try self.reply(["ok": .bool(true)])
        }
        await model.play(explicit: true)
        XCTAssertEqual(items.count,2); XCTAssertFalse(model.player.currentItem === failedItem)
        XCTAssertEqual(refreshed,[originalSource]); XCTAssertEqual(itemSources,[originalSource,fresh.url])
        XCTAssertEqual(seeks,[120,430]); XCTAssertEqual(model.lease?.generation,9)
        blocked.open(); await first.value
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,object: failedItem)
        XCTAssertEqual(model.lease?.generation,9, "The old item's late failure cannot release its replacement")
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/progress" })
        await model.close()
    }

    func testFixtureAndInvalidIdentityNeverAcquireOrWriteProgress() async throws {
        let http = PlaybackHTTP()
        http.respond = { _ in XCTFail("Untracked/fixture playback may not contact Sync"); return try self.reply([:]) }
        let fixture = try make(http,fixture: true)
        var invalid = metadata; invalid.animeID = ""
        let untracked = try make(http,metadata: invalid)
        for model in [fixture,untracked] {
            await model.play(explicit: true); await model.save(ended: true); await model.background()
            XCTAssertNil(model.lease)
        }
        XCTAssertTrue(fixture.player.isMuted); XCTAssertTrue(http.requests.isEmpty)
    }

    func testHandoffKeepsPlaybackPausedThroughTheCallersTransfer() async throws {
        let http = PlaybackHTTP(), saveGate = gate("handoff save is awaiting acknowledgement")
        http.respond = { request in
            if request.url?.path == "/api/progress", request.httpMethod == "POST" { await saveGate.wait() }
            return try self.defaultResponse(request)
        }
        let model = try make(http)
        await model.play(explicit: true)
        let completed = expectation(description: "accepted handoff snapshot")
        var snapshot: HandoffSnapshot?
        let transfer = Task {
            do { snapshot = try await model.handoff() } catch { XCTFail("Fixture handoff failed: \(error)") }
            completed.fulfill()
        }
        tasks.append(transfer)
        await fulfillment(of: [saveGate.started],timeout: 3)
        XCTAssertTrue(model.handoffInProgress)
        model.player.play()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(model.player.rate,0, "AVPlayer controls cannot resume during an unacknowledged transfer")
        await model.play(explicit: true)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/playback" }.count,1)
        saveGate.open()
        await fulfillment(of: [completed],timeout: 3)
        XCTAssertTrue(try XCTUnwrap(snapshot).saved)
        XCTAssertTrue(model.handoffInProgress, "The lock must outlive save and include the caller's TV validation/load")
        model.cancelHandoff()
        XCTAssertFalse(model.handoffInProgress); XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.lease)
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.snapshot(2,session: "previous-iphone-session")) }
            if request.url?.path == "/api/playback" { return try self.reply(self.snapshot(3)) }
            return try self.reply(["ok": .bool(true)])
        }
        await model.play(explicit: true)
        XCTAssertEqual(model.lease?.generation,3, "Failed transfer unlocks only a later fresh Play intent")
    }

    func testCanceledOldStartCannotClearNewerStartingIntent() async throws {
        let http = PlaybackHTTP(), firstGate = gate("canceled start head"), secondGate = gate("replacement start head")
        var reads = 0
        http.respond = { request in
            if request.httpMethod == "GET" {
                reads += 1
                if reads == 1 { await firstGate.wait() } else if reads == 2 { await secondGate.wait() }
                return try self.reply(self.snapshot(1))
            }
            return try self.reply(self.snapshot(2))
        }
        let model = try make(http)
        let first = Task { await model.play(explicit: true) }; tasks.append(first)
        await fulfillment(of: [firstGate.started],timeout: 3)
        await model.background(); first.cancel()
        let second = Task { await model.play(explicit: true) }; tasks.append(second)
        await Task.yield(); firstGate.open()
        await fulfillment(of: [secondGate.started],timeout: 3)
        await first.value
        XCTAssertTrue(model.isStarting, "Canceled predecessor must not clear the replacement's loading state")
        secondGate.open(); await second.value
        XCTAssertEqual(model.lease?.generation,2)
    }

    func testPrivateSubtitleSourceCannotReachTheTransport() throws {
        let http = PlaybackHTTP(), captions = PlaybackHTTP()
        captions.respond = { _ in XCTFail("Private subtitle URL reached HTTP transport"); return try self.reply([:]) }
        let model = try make(http,captionTransport: captions)
        model.selectSubtitle(SubtitleSource(url: URL(string: "https://10.0.0.10/private.vtt")!,label: "Blocked track"))
        XCTAssertTrue(captions.requests.isEmpty)
        XCTAssertEqual(model.captionSelection,"automatic")
        XCTAssertTrue(model.message.contains("website"))
    }

    func testPausedExternalCueAndTimingChangeUpdateWithoutAPlaybackTick() async throws {
        let http = PlaybackHTTP(), captions = PlaybackHTTP()
        http.respond = { _ in XCTFail("Paused caption selection must not acquire/write progress"); return try self.reply([:]) }
        captions.respond = { _ in HTTPReply(status: 200,body: Data("WEBVTT\n\n00:01:59.000 --> 00:02:01.000\nPaused cue\n\n".utf8)) }
        let model = try make(http,captionTransport: captions)
        let shown = expectation(description: "paused cue rendered in model")
        let observation = model.$captionText.filter { $0 == "Paused cue" }.first().sink { _ in shown.fulfill() }
        defer { observation.cancel() }
        model.selectSubtitle(SubtitleSource(url: URL(string: "https://cdn.example/paused.vtt")!,label: "Fixture",language: "en"))
        await fulfillment(of: [shown],timeout: 3)
        XCTAssertEqual(model.captionText,"Paused cue")
        XCTAssertEqual(model.player.rate,0); XCTAssertNil(model.player.currentItem,"No media item means no playback tick supplied the update")
        model.captionDelay = 5; XCTAssertEqual(model.captionText,"")
        model.captionDelay = 0; XCTAssertEqual(model.captionText,"Paused cue")
        model.selectSubtitle(nil); XCTAssertEqual(model.captionText,"")
        XCTAssertEqual(captions.requests.count,1); XCTAssertTrue(http.requests.isEmpty)
    }

    func testPausedUserScrubOverridesResumeButUnmarkedOrBackgroundJumpsDoNot() async throws {
        let http = PlaybackHTTP()
        http.respond = { request in
            if request.httpMethod == "GET" || request.url?.path == "/api/playback" {
                var response = self.snapshot(request.httpMethod == "GET" ? 1 : 2)
                response["progress"] = .object(["current_time": .number(200),"duration": .number(1000),"completed": .bool(false)])
                return try self.reply(response)
            }
            return try self.reply(["ok": .bool(true)])
        }
        for (marked,background,expected) in [(false,false,200.0),(true,false,300.0),(true,true,200.0)] {
            var seeks: [Double] = []
            let model = try make(http,clock: { (position: 300,duration: 1000) },seek: { _,at in seeks.append(at) })
            // A local, zero-track item supplies event identity. videoReady is a
            // synthetic state precondition here; only UI tests prove real frames.
            let item = AVPlayerItem(asset: AVMutableComposition())
            model.player.replaceCurrentItem(with: item); model.videoReady = true
            if marked { model.beginUserScrub() }
            NotificationCenter.default.post(name: .AVPlayerItemTimeJumped,object: item)
            if marked { model.endUserScrub(cancelled: false) }
            if background { await model.background() }
            await model.play(explicit: true)
            XCTAssertEqual(seeks.first,expected, "Only a current, explicit paused scrub may override the fresh checkpoint")
        }
    }
}

final class SubtitleTextTests: XCTestCase {
    func testVttAndSrtBoundariesAndPlainMarkup() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:03.000 align:start\n<i>Hello &amp; goodbye</i>\n\n"
        let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\nHello &amp; goodbye\r\n\r\n"
        let cues = SubtitleText.parse(vtt,extension: "vtt")
        XCTAssertEqual(cues,SubtitleText.parse(srt,extension: "srt"))
        XCTAssertEqual(SubtitleText.active(cues,at: 0.999),"")
        XCTAssertEqual(SubtitleText.active(cues,at: 1),"Hello & goodbye")
        XCTAssertEqual(SubtitleText.active(cues,at: 3),"")
    }
    func testAssReorderedTimingFieldsAndCommasKeepPlainDialogue() {
        let text = "[Events]\nFormat: Layer, End, Start, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:03.00,0:00:01.00,Default,,0,0,0,,{\\i1}Hello, world\\NSecond line\n"
        let cues = SubtitleText.parse(text,extension: "ass")
        XCTAssertEqual(cues,[SubtitleCue(start: 1,end: 3,text: "Hello, world\nSecond line")])
    }
    func testStoryboardCueDoesNotCoverSimultaneousDialogue() {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:04.000
        https://example.test/preview.jpg?token=abc#xywh=0,0,160,90

        00:01.500 --> 00:03.000
        Keep this dialogue.

        00:03.000 --> 00:04.000
        Look at https://example.test/photo.jpg#xywh=0,0,160,90
        """
        let cues = SubtitleText.parse(vtt,extension: "vtt")
        XCTAssertEqual(SubtitleText.active(cues,at: 1),"")
        XCTAssertEqual(SubtitleText.active(cues,at: 2),"Keep this dialogue.")
        XCTAssertTrue(SubtitleText.active(cues,at: 3.5).hasPrefix("Look at"))
    }
    func testInvalidAndEmptyCaptionInputDoesNotManufactureCues() {
        for text in ["", "not subtitles", "00:03 --> 00:01\nbackwards\n", "00:99 --> 00:100\ninvalid\n"] {
            XCTAssertTrue(SubtitleText.parse(text,extension: "srt").isEmpty)
        }
        XCTAssertEqual(SubtitleText.active([],at: .nan),"")
    }
}


final class EpisodeContinuationTests: XCTestCase {
    func testNextUsesVerifiedInventoryAndClearsOldResume() throws {
        let watch = try XCTUnwrap(URL(string: "https://miruro.cx/watch/example/title?ep=1"))
        let metadata = AnimeMetadata(animeID: "42",episode: "1",title: "Example",watchURL: watch)
        let later = EpisodeChoice(id: "3",label: "3",number: "3",url: URL(string: "https://miruro.cx/watch/example/title?ep=3"))
        let next = EpisodeChoice(id: "1.5",label: "1.5",number: "1.5",url: URL(string: "https://miruro.cx/watch/example/title?ep=1.5&lang=en#anime-sync-t=120"))
        XCTAssertEqual(EpisodeChoice.next(in: [later,next],after: metadata)?.url?.absoluteString,"https://miruro.cx/watch/example/title?ep=1.5")
        var wrong = next; wrong.url = URL(string: "https://miruro.cx/watch/other/title?ep=1.5")
        XCTAssertNil(EpisodeChoice.next(in: [wrong,later],after: metadata))
        var finale = metadata; finale.episode = "3"
        XCTAssertNil(EpisodeChoice.next(in: [later,next],after: finale))
    }
    func testSegmentsRequireExactBoundsAndMatchingDuration() throws {
        let segments = PlaybackSegment.parse([
            .object(["kind": .string("intro"),"start": .integer(31),"end": .integer(111)]),
            .object(["kind": .string("outro"),"start": .number(.infinity),"end": .integer(130)]),
            .object(["kind": .string("outro"),"start": .string("110"),"end": .integer(120)])
        ])
        XCTAssertEqual(segments.count,1)
        let opening = try XCTUnwrap(segments.first)
        XCTAssertFalse(opening.contains(30.999,duration: 1447))
        XCTAssertTrue(opening.contains(31,duration: 1447))
        XCTAssertFalse(opening.contains(111,duration: 1447))
        XCTAssertFalse(opening.contains(31,duration: 80))
    }
}
