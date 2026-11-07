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
    private func snapshot(_ generation: Int64, session: String = "") -> JSONObject {
        ["sync": .object(["generation": .integer(generation),"session_id": .string(session)]),
         "progress": .object(["current_time": .number(120),"duration": .number(1000),"completed": .bool(false)])]
    }
    private func make(_ http: PlaybackHTTP, fixture: Bool = false, metadata item: AnimeMetadata? = nil, captionTransport: HTTPTransport? = nil, clock: (() -> (position: TimeInterval,duration: TimeInterval))? = nil, seek: ((AVPlayer,TimeInterval) async -> Void)? = nil) throws -> NativePlaybackModel {
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
                                        subtitles: [],sync: sync,fixture: fixture,clock: clock ?? { (position: 120,duration: 1000) },captionTransport: captionTransport,seekOperation: seek ?? { _,_ in })
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

    func testChromeUsesLetterboxSpaceInPortraitAndActualImageWidthInLandscape() {
        let portraitViewport = CGRect(x: 0,y: 0,width: 402,height: 874)
        let portraitVideo = CGRect(x: 0,y: 286,width: 402,height: 302)
        let portraitInsets = UIEdgeInsets(top: 62,left: 0,bottom: 34,right: 0)
        let portrait = NativeChromeLayout.fitted(video: portraitVideo,viewport: portraitViewport,safeInsets: portraitInsets)
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
        XCTAssertEqual(landscape.dock.midX,image.midX)
        XCTAssertEqual(landscape.dock.width,340)
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
        model.updateCaptionViewport(video: CGRect(x: 164,y: 0,width: 524,height: 393),controls: CGRect(x: 12,y: 271,width: 828,height: 100))
        let raised = try XCTUnwrap(model.player.currentItem?.textStyleRules?.first?.textMarkupAttributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] as? NSNumber)
        XCTAssertLessThan(raised.doubleValue,90)
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
        XCTAssertNotNil(originalFont[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String],"Visible controls still need caption avoidance with an original-font preference")
        model.updateCaptionViewport(video: CGRect(x: 164,y: 0,width: 524,height: 393),controls: nil)
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
        XCTAssertEqual(model.captionSelection,"embedded"); XCTAssertEqual(captions.requests.count,1)
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
        model.player.pause()
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

    func testOwnedForegroundMayContinueTheCapturedCurrentGeneration() async throws {
        let http = PlaybackHTTP(); http.respond = { try self.defaultResponse($0) }
        let model = try make(http)
        await model.play(explicit: true); await model.background()
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
    func testInvalidAndEmptyCaptionInputDoesNotManufactureCues() {
        for text in ["", "not subtitles", "00:03 --> 00:01\nbackwards\n", "00:99 --> 00:100\ninvalid\n"] {
            XCTAssertTrue(SubtitleText.parse(text,extension: "srt").isEmpty)
        }
        XCTAssertEqual(SubtitleText.active([],at: .nan),"")
    }
}
