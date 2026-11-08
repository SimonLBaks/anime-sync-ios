import XCTest
import CoreGraphics
import UIKit

/// Runs only the full app's Debug fixture mode. No real account or TV receiver.
/// Protocol races belong to ProtocolTests; these assert native controls/transitions.
final class QAAcceptanceTests: XCTestCase {
    @MainActor private func launch(_ flags: String...) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa-fixture"] + flags
        app.launch()
        XCTAssertTrue(element(app, "nav.toggle").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "screen.home").waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let buttons = ["nav.toggle", "search.submit", "destination.here", "destination.tv", "destination.website", "tv.pill", "tv.close", "tv.connect", "tv.playpause", "tv.episodes", "tv.episode.submit", "tv.pair.submit", "tv.pair.cancel", "tv.control.takeover", "player.close", "player.subtitles", "player.subtitle.done", "player.subtitle.off", "player.subtitle.larger", "player.subtitle.raise"]
        if buttons.contains(id) || ["episodes.current","episodes.ranges","player.play-pause","player.skip.back","player.skip.forward"].contains(id) || id.hasPrefix("episode.choice.") || id.hasPrefix("nav.item.") || id.hasPrefix("library.filter.") || id.hasPrefix("player.subtitle.track.") { return app.buttons.matching(identifier: id).firstMatch }
        if ["search.field", "library.search", "tv.pair.address", "tv.pair.pin", "tv.episode.number"].contains(id) { return app.textFields.matching(identifier: id).firstMatch }
        if ["qa.tv.command-count", "qa.player.ready", "qa.player.time", "player.caption", "player.time", "tv.control.status"].contains(id) { return app.staticTexts.matching(identifier: id).firstMatch }
        if ["nav.pane", "row.continue", "row.history", "tv.content", "screen.anime-sync","screen.episode","episodes.list"].contains(id) { return app.scrollViews.matching(identifier: id).firstMatch }
        if ["tv.seek","player.timeline"].contains(id) { return app.sliders.matching(identifier: id).firstMatch }
        if id == "player.subtitle.style" { return app.switches.matching(identifier: id).firstMatch }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func gone(_ item: XCUIElement, timeout: TimeInterval = 4) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    @MainActor private func gone(_ query: XCUIElementQuery, timeout: TimeInterval = 4) {
        // Resolving firstMatch.exists for a missing AVPlayer descendant can
        // spend the entire deadline retrying a lookup. Count a fresh snapshot
        // instead; the required result remains exactly zero matching elements.
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in query.count == 0 },object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation],timeout: timeout),.completed)
    }

    @MainActor private func openNavigation(_ app: XCUIApplication) -> XCUIElement {
        let query = app.scrollViews.matching(identifier: "nav.pane"), pane = query.firstMatch
        for _ in 0..<2 {
            if query.count == 0 { element(app,"nav.toggle").tap() }
            if pane.waitForExistence(timeout: 3) { return pane }
            // Accessibility inspection can consume the real five-second idle
            // window between the count and existence checks. Reopen through
            // the logo once, as a user would, without changing that policy.
        }
        XCTFail("The navigation pane must open after a real logo interaction")
        return pane
    }

    @MainActor private func tapNavigation(_ app: XCUIApplication, _ section: String) {
        var pane = openNavigation(app), viewport = pane.frame
        let target = element(app, "nav.item." + section)
        var swipes = 0, reopens = 0
        for _ in 0..<5 {
            let frame = target.frame, visible = viewport.intersection(frame)
            if frame.isEmpty {
                // A keyboard-heavy snapshot outlived the real idle deadline.
                // An absent row is not evidence that the pane needs scrolling.
                guard reopens < 2 else { XCTFail("The menu expired repeatedly before its requested row could be measured"); return }
                pane = openNavigation(app); viewport = pane.frame; swipes = 0; reopens += 1
                continue
            }
            if !visible.isEmpty, visible.height >= min(20,frame.height), visible.width >= min(40,frame.width) {
                let appFrame = app.frame
                let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX - appFrame.minX,dy: visible.midY - appFrame.minY))
                // Resolving pane/row geometry consumed >5s in the real failure
                // trace. Reset through actual logo interactions, not a disabled
                // idle timer, then inject the cached hit without another query.
                let logo = element(app,"nav.toggle")
                logo.tap()
                let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@","Open menu"),object: logo)
                XCTAssertEqual(XCTWaiter.wait(for: [closed],timeout: 8),.completed)
                logo.tap()
                for _ in 0..<swipes { pane.swipeUp() }
                point.tap()
                return
            }
            if app.scrollViews.matching(identifier: "nav.pane").count == 0 {
                guard reopens < 2 else { XCTFail("The menu expired repeatedly before scrolling"); return }
                pane = openNavigation(app); viewport = pane.frame; swipes = 0; reopens += 1
                continue
            }
            pane.swipeUp(); swipes += 1
        }
        XCTFail("Destination must be reachable: \(section)")
    }

    @MainActor private func select(_ app: XCUIApplication, _ section: String) {
        tapNavigation(app,section)
        gone(app.scrollViews.matching(identifier: "nav.pane"))
        XCTAssertTrue(element(app, "screen." + section).waitForExistence(timeout: 5))
    }

    @MainActor private func cards(_ row: XCUIElement) -> [XCUIElement] {
        row.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "card.")).allElementsBoundByIndex
    }

    @MainActor private func fullyVisible(_ card: XCUIElement, in row: XCUIElement, app: XCUIApplication,contentViewport: CGRect? = nil) -> Bool {
        let frame = card.frame
        let viewport = row.frame.intersection(contentViewport ?? app.frame)
        return !frame.isEmpty && !viewport.isEmpty && frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1
            && frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.maxY + 1
    }

    @MainActor private func assertHeaderFits(_ app: XCUIApplication) {
        let viewport = app.frame, pill = element(app,"tv.pill").frame
        XCTAssertGreaterThan(pill.width,40)
        XCTAssertGreaterThanOrEqual(pill.minX,viewport.minX)
        XCTAssertLessThanOrEqual(pill.maxX,viewport.maxX,"A real wide backdrop must not push the TV control off screen")
    }

    @MainActor private func setText(_ app: XCUIApplication, _ id: String, _ text: String,replacing knownText: String? = nil,alreadyPresent: Bool = false) {
        let field = element(app, id)
        if !alreadyPresent { XCTAssertTrue(field.waitForExistence(timeout: 4)) }
        let current = knownText ?? (field.value as? String ?? "")
        field.tap()
        // Deleting a placeholder's length from an empty field is harmless and
        // avoids another expensive snapshot just to ask for placeholderValue.
        // Inject into the focused app, avoiding another expensive lookup of
        // the same field while the keyboard changes the accessibility tree.
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,count: min(2000,current.count)) + text)
    }

    @MainActor private func waitForText(_ app: XCUIApplication, _ id: String, _ text: String) {
        let field = element(app,id)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@",text),object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [settled],timeout: 12),.completed,"The keyboard must enter the complete value in \(id)")
    }

    @MainActor private func openTV(_ app: XCUIApplication) {
        if !element(app, "tv.content").exists { element(app, "tv.pill").tap() }
        XCTAssertTrue(element(app, "tv.close").waitForExistence(timeout: 4))
    }

    @MainActor private func openConnect(_ app: XCUIApplication,fromTVPanel: Bool = false) {
        if !fromTVPanel { openTV(app) }
        element(app, "tv.connect").tap()
        XCTAssertTrue(element(app, "tv.pair.address").waitForExistence(timeout: 4))
        XCTAssertTrue(element(app, "tv.pair.pin").exists)
    }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor private func expose(_ target: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<6 { if target.isHittable { return }; scroll.swipeUp() }
        XCTFail("The requested control must become actionable after scrolling")
    }

    @MainActor private func pullToRefresh(_ scroll: XCUIElement, app: XCUIApplication) {
        let appFrame = app.frame, viewport = scroll.frame.intersection(appFrame)
        XCTAssertFalse(viewport.isNull || viewport.isEmpty,"Refresh gesture needs an actual visible scroll viewport")
        // Constrain the whole gesture to the visible viewport. A semantic
        // swipeDown chooses its own short flick and need not cross the native
        // refresh threshold, especially when it starts over a poster button.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: viewport.midX - appFrame.minX,dy: viewport.minY + viewport.height * 0.28 - appFrame.minY))
        let to = origin.withOffset(CGVector(dx: viewport.midX - appFrame.minX,dy: viewport.minY + viewport.height * 0.92 - appFrame.minY))
        // The recorded immediate-release drag stretched content but never
        // armed refresh. Hold a slow, real pull across the native threshold;
        // the test still requires a changed complete-snapshot witness.
        from.press(forDuration: 0.1,thenDragTo: to,withVelocity: .slow,thenHoldForDuration: 0.5)
    }

    @MainActor private func playerCoordinate(_ app: XCUIApplication, at point: CGPoint, viewport: CGRect) -> XCUICoordinate {
        XCTAssertTrue(viewport.contains(point),"Player touch must be within the app viewport")
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - viewport.minX,dy: point.y - viewport.minY))
    }

    @MainActor private func videoTapPoint(_ app: XCUIApplication, viewport: CGRect) -> XCUICoordinate {
        let image = element(app,"qa.player.video-region").frame
        XCTAssertGreaterThan(image.height,100)
        return playerCoordinate(app,at: CGPoint(x: image.midX,y: image.minY + image.height * 0.3),viewport: viewport)
    }

    @MainActor private func assertNativeCaptionAndTransportFit(_ app: XCUIApplication,caption: XCUIElement) {
        let image = element(app,"qa.player.video-region").frame
        let dock = element(app,"player.transport").frame
        let text = caption.frame, appFrame = app.frame, viewport = appFrame.insetBy(dx: -1,dy: -1)
        XCTAssertGreaterThan(image.width,100); XCTAssertGreaterThan(image.height,100)
        XCTAssertTrue(viewport.contains(image)); XCTAssertTrue(viewport.contains(dock))
        XCTAssertTrue(image.insetBy(dx: -1,dy: -1).contains(text),"Captions must remain inside the actual displayed video, including a pillarboxed source")
        XCTAssertLessThan(text.width,image.width - 8,"The caption element must fit text instead of becoming a full-width subtitle strip")
        XCTAssertFalse(text.intersects(dock),"Visible playback controls must not cross a caption line")
        let shortcut = element(app,"player.skip.90")
        XCTAssertTrue(shortcut.isHittable)
        XCTAssertEqual(shortcut.frame.maxY,dock.minY,accuracy: 2,"The shortcut row sits flush above the dock")
        XCTAssertFalse(text.intersects(shortcut.frame))
        let back = element(app,"player.close").frame, subtitles = element(app,"player.subtitles").frame
        XCTAssertTrue(viewport.contains(back)); XCTAssertTrue(viewport.contains(subtitles))
        XCTAssertTrue(back.intersection(subtitles).isNull || back.intersection(subtitles).isEmpty)
        if appFrame.height > appFrame.width {
            XCTAssertLessThanOrEqual(image.maxY - text.maxY,max(5,image.height * 0.035),"Portrait captions stay close to the lower picture edge")
            XCTAssertLessThanOrEqual(back.maxY,image.minY,"Portrait actions should use the nearby upper letterbox")
            XCTAssertLessThanOrEqual(image.minY - back.maxY,16)
            // UIKit video and SwiftUI controls report independently rounded accessibility frames.
            XCTAssertGreaterThanOrEqual(dock.minY,image.maxY - 1,"Portrait playback controls should sit directly below the image")
            XCTAssertLessThanOrEqual(shortcut.frame.minY - image.maxY,16)
        } else {
            XCTAssertEqual(dock.midX,appFrame.midX,accuracy: 2)
            XCTAssertGreaterThan(dock.width,appFrame.width * 0.5,"Landscape dock gives the timeline more room")
            XCTAssertLessThanOrEqual(dock.width,601)
            XCTAssertLessThanOrEqual(appFrame.maxY - dock.maxY,42,"Landscape dock sits near the safe bottom edge")
            XCTAssertLessThanOrEqual(dock.height,112,"Keep the larger buttons in a shallow dock")
            if image.intersects(dock) { XCTAssertLessThanOrEqual(text.maxY,shortcut.frame.minY) }
        }
        var controlFrames: [String:CGRect] = [:]
        for id in ["player.play-pause","player.skip.back","player.skip.forward","player.timeline"] {
            let control = element(app,id)
            let frame = control.frame
            controlFrames[id] = frame
            XCTAssertGreaterThan(frame.width,0); XCTAssertGreaterThan(frame.height,0)
            XCTAssertTrue(dock.insetBy(dx: -1,dy: -1).contains(frame),"Transport control must stay inside the single dock: \(id)")
            XCTAssertTrue(control.isHittable)
        }
        let play = controlFrames["player.play-pause"]!, previous = controlFrames["player.skip.back"]!, next = controlFrames["player.skip.forward"]!
        for frame in [play, previous, next] {
            XCTAssertGreaterThanOrEqual(frame.width,43)
            XCTAssertGreaterThanOrEqual(frame.height,43,"The visual reduction must preserve full-size transport touch targets")
        }
        XCTAssertEqual(play.midX,dock.midX,accuracy: 1,"Play/Pause must stay centered independently of timer text or loading indicators")
        XCTAssertEqual(play.midX - previous.midX,next.midX - play.midX,accuracy: 1)
        XCTAssertEqual(previous.midY,play.midY,accuracy: 1); XCTAssertEqual(next.midY,play.midY,accuracy: 1)
        let timeline = controlFrames["player.timeline"]!, timer = element(app,"player.time").frame
        XCTAssertGreaterThan(timer.width,0); XCTAssertTrue(dock.insetBy(dx: -1,dy: -1).contains(timer))
        XCTAssertLessThanOrEqual(timer.maxY,timeline.minY + 1,"Combined time belongs above the actual slider")
        XCTAssertLessThanOrEqual(abs(timer.midY - play.midY),10)
        XCTAssertLessThanOrEqual(timer.maxX,previous.minX,"The time readout must clear the playback buttons")
        XCTAssertEqual(timer.minX,timeline.minX,accuracy: 2,"Time must align with the slider's left edge")
    }

    @MainActor func testPaneLabelsLogoOutsideIdleAndLandscapeReachability() {
        let app = launch()
        let pane = openNavigation(app)
        let paneFrame = pane.frame
        let names = ["home", "trending", "discover", "search", "schedule", "history", "announcements", "profile", "anime-sync", "tv", "settings", "login"]
        let hierarchy = pane.debugDescription
        for name in names { XCTAssertTrue(hierarchy.contains("nav.item." + name), "Missing navigation entry \(name)") }
        let widestLabel = names.map { name -> CGFloat in
            let label = name == "anime-sync" ? "Anime Sync" : name.capitalized
            return (label as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14,weight: .medium)]).width
        }.max() ?? 0
        XCTAssertGreaterThanOrEqual(paneFrame.width,widestLabel + 24 + 14 + 28 + 12,"The real pane must fit its widest single-line label, icon and insets")
        _ = openNavigation(app)
        element(app, "nav.toggle").tap()
        gone(app.scrollViews.matching(identifier: "nav.pane"))
        _ = openNavigation(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.35)).tap()
        gone(app.scrollViews.matching(identifier: "nav.pane"))
        _ = openNavigation(app)
        gone(app.scrollViews.matching(identifier: "nav.pane"),timeout: 8) // Real five-second touch-idle policy.
        tapNavigation(app,"trending")
        gone(app.scrollViews.matching(identifier: "nav.pane"))
        XCTAssertTrue(element(app, "screen.trending").waitForExistence(timeout: 4))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let shortPane = openNavigation(app)
        let login = element(app, "nav.item.login"), appFrame = app.frame
        var reached = false
        for _ in 0..<5 {
            let viewport = shortPane.frame.intersection(appFrame), frame = login.frame
            if !viewport.isEmpty, !frame.isEmpty, viewport.insetBy(dx: -1,dy: -1).contains(frame) {
                // Accessibility exposes Login's icon/label content bounds;
                // its natural width is not the padded row's tap-target width.
                // Require that complete content to fit the clipped viewport,
                // then prove the final row can actually be activated.
                let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - appFrame.minX,dy: frame.midY - appFrame.minY))
                target.tap(); reached = true; break
            }
            shortPane.swipeUp()
        }
        XCTAssertTrue(reached,"Short landscape pane must scroll to its final label")
        gone(app.scrollViews.matching(identifier: "nav.pane"))
        XCTAssertTrue(app.staticTexts["Login"].waitForExistence(timeout: 4),"The final landscape entry must navigate when tapped")
    }

    @MainActor func testHomeContinueBelowHeroThreePostersAndSeparateHistoryTen() {
        let app = launch()
        assertHeaderFits(app)
        // WK container nodes can remain queryable even when UIKit hides their
        // accessibility descendants. Native mode must expose no web controls.
        XCTAssertFalse(app.webViews.textFields.firstMatch.exists,"Native Home must not expose editable website controls")
        XCTAssertFalse(app.webViews.buttons.firstMatch.exists,"Native Home must not expose actionable website controls")
        let hero = element(app, "home.hero"), continuing = element(app, "row.continue")
        let contentViewport = element(app,"screen.home").frame.intersection(app.frame)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(continuing.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(hero.frame.maxY, continuing.frame.minY + 1)
        XCTAssertFalse(element(app, "row.history").exists)
        var firstCards = cards(continuing)
        XCTAssertGreaterThanOrEqual(firstCards.count, 3)
        // Home may legitimately need vertical scrolling below its featured hero.
        for _ in 0..<3 {
            if firstCards.prefix(3).allSatisfy({ fullyVisible($0, in: continuing, app: app,contentViewport: contentViewport) }) { break }
            app.swipeUp()
            firstCards = cards(continuing)
        }
        for card in firstCards.prefix(3) { XCTAssertTrue(fullyVisible(card, in: continuing, app: app,contentViewport: contentViewport), "Three complete unfocused portrait cards") }
        let firstID = firstCards[0].identifier
        screenshot(app, "fixture-home-three-posters")
        continuing.swipeLeft()
        firstCards = cards(continuing)
        XCTAssertTrue(firstCards.contains { $0.identifier != firstID && fullyVisible($0,in: continuing,app: app,contentViewport: contentViewport) && $0.isHittable },"A horizontal swipe must expose another complete, actionable poster")
        select(app, "history")
        XCTAssertFalse(element(app, "row.continue").exists)
        let recent = element(app, "row.history")
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        var identities = Set<String>()
        for _ in 0..<7 {
            for card in cards(recent) { identities.insert(card.identifier) }
            recent.swipeLeft()
            XCTAssertTrue(element(app, "screen.history").exists, "Poster drag must not navigate")
        }
        XCTAssertEqual(identities.count, 10, "History fixture exposes ten distinct anime, including offscreen entries")
    }

    @MainActor func testSearchPositiveEmptyAndKeyboardUsable() {
        let app = launch()
        select(app, "search")
        setText(app, "search.field", "One Piece",replacing: "")
        element(app, "search.submit").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "card.")).firstMatch.waitForExistence(timeout: 5))
        setText(app, "search.field", "zzqaempty",replacing: "One Piece")
        element(app, "search.submit").tap()
        XCTAssertTrue(element(app, "search.empty").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "card.")).firstMatch.exists, "Empty query may not retain old cards")
        XCTAssertTrue(element(app, "screen.search").exists)
    }

    @MainActor func testPreviousPageEdgeBackUnwindsVisitedSections() {
        let app = launch()
        select(app, "trending")
        select(app, "discover")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.45))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(element(app, "screen.trending").waitForExistence(timeout: 4))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(element(app, "screen.home").waitForExistence(timeout: 4))
        XCTAssertTrue(element(app, "nav.toggle").exists)
    }

    @MainActor func testNativeLibraryFiltersSearchAndReturn() {
        let app = launch()
        select(app, "anime-sync")
        let library = element(app,"screen.anime-sync")
        let expected = [
            "continue": ["card.miruro:22","card.miruro:23","card.miruro:25"],
            "new": ["card.miruro:21","card.miruro:24","card.miruro:27"],
            "all": ["card.miruro:21","card.miruro:22","card.miruro:23"]
        ]
        func assertFirstCards(_ filter: String) {
            let ids = expected[filter]!
            XCTAssertTrue(app.buttons.matching(identifier: ids[0]).firstMatch.waitForExistence(timeout: 6))
            XCTAssertEqual(Array(cards(library).prefix(3)).map(\.identifier),ids,"\(filter) must show the actual expected series, not only a persistent screen shell")
        }
        for filter in ["continue", "new", "all", "continue"] {
            let button = element(app, "library.filter." + filter)
            XCTAssertTrue(button.waitForExistence(timeout: 4)); button.tap()
            assertFirstCards(filter)
        }
        let witness = app.buttons.matching(identifier: "card.miruro:22").firstMatch
        let beforeRefresh = witness.label
        pullToRefresh(library,app: app)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND label != %@","refreshed",beforeRefresh),object: witness)
        let refreshResult = XCTWaiter.wait(for: [refreshed],timeout: 10)
        if refreshResult != .completed { screenshot(app,"fixture-library-pull-refresh-failed") }
        XCTAssertEqual(refreshResult,.completed,"A changed complete-snapshot witness proves the real pull-to-refresh gesture ran")
        assertFirstCards("continue")
        element(app,"library.filter.all").tap(); assertFirstCards("all")
        let initial = cards(library)
        XCTAssertGreaterThanOrEqual(initial.count,3)
        for card in initial.prefix(3) { XCTAssertTrue(fullyVisible(card,in: library,app: app),"The native Library must lay out three measurable poster cells") }
        for _ in 0..<2 {
            library.swipeUp()
            let viewport = library.frame.intersection(app.frame)
            XCTAssertTrue(cards(library).contains { card in
                let frame = card.frame, visible = frame.intersection(viewport)
                return frame.height > 100 && visible.width > 40 && visible.height > 40
            },"Scrolling a nonempty Library must retain actual visible poster cells")
        }
        library.swipeDown(); library.swipeDown()
        setText(app, "library.search", "One Piece",replacing: "")
        let onePiece = app.buttons.matching(identifier: "card.miruro:21").firstMatch
        XCTAssertTrue(onePiece.waitForExistence(timeout: 6))
        XCTAssertEqual(cards(library).map(\.identifier),["card.miruro:21"],"Native search must filter actual cards")
        app.typeText("\n") // Finish the actual library input before navigating away.
        select(app, "home")
        XCTAssertTrue(element(app, "home.hero").waitForExistence(timeout: 4))
    }

    @MainActor func testViewerCancelThenExplicitControlOnlyTakeover() {
        let app = launch("--qa-tv-occupied")
        openTV(app)
        let count = element(app, "qa.tv.command-count")
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        let before = count.label
        screenshot(app, "fixture-tv-viewer-panel")
        element(app, "tv.playpause").tap()
        XCTAssertTrue(app.staticTexts["Take over TV?"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertEqual(count.label, before, "Canceled viewer action must send no TV mutation")
        XCTAssertFalse(element(app, "tv.control.status").label.contains("You control"))
        element(app, "tv.control.takeover").tap()
        XCTAssertTrue(app.staticTexts["Take over TV?"].waitForExistence(timeout: 3))
        app.buttons["Take over"].firstMatch.tap()
        let owner = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "You control this TV"), object: element(app, "tv.control.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [owner], timeout: 5), .completed)
        XCTAssertEqual(count.label, before, "Control-only takeover must not send playback/navigation")
        element(app, "tv.close").tap()
        XCTAssertTrue(element(app, "screen.home").exists)
    }

    @MainActor func testOwnedTVTransportEpisodeAndRemoteNavigation() {
        let app = launch()
        openTV(app)
        let count = element(app, "qa.tv.command-count")
        XCTAssertTrue(count.waitForExistence(timeout: 4))
        func expectCount(_ number: Int) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", String(number)),object: count)
            let result = XCTWaiter.wait(for: [changed],timeout: 10)
            if result != .completed { screenshot(app,"fixture-tv-mutation-count-failed-\(number)") }
            XCTAssertEqual(result,.completed,"Expected \(number) receiver mutations; actual counter label \(count.label)")
        }
        element(app, "tv.playpause").tap(); expectCount(1)
        element(app, "tv.seek").adjust(toNormalizedSliderPosition: 0.6); expectCount(2)
        element(app, "tv.episodes").tap()
        let number = element(app, "tv.episode.number")
        XCTAssertTrue(number.waitForExistence(timeout: 4))
        XCTAssertEqual(number.value as? String,"7", "Integer episode offers the next number for explicit confirmation")
        element(app, "tv.episode.submit").tap(); expectCount(3)
        let scroll = element(app, "tv.content"), remote = element(app, "tv.remote.expand")
        expose(remote,in: scroll); remote.tap()
        let back = app.buttons["TV Back"].firstMatch
        expose(back,in: scroll); back.tap(); expectCount(4)
        let home = app.buttons["TV Home"].firstMatch
        expose(home,in: scroll); home.tap(); expectCount(5)
        element(app, "tv.close").tap()
        XCTAssertTrue(element(app, "screen.home").exists)
    }

    @MainActor func testUnpairedConnectionValidationCancelAndReopen() {
        let app = launch("--qa-tv-unpaired")
        openConnect(app)
        setText(app, "tv.pair.address", "8.8.8.8",replacing: "10.0.0.20",alreadyPresent: true)
        // The recording showed the last key appear after the immediate AX read.
        waitForText(app,"tv.pair.address","8.8.8.8")
        setText(app, "tv.pair.pin", "000000",replacing: "",alreadyPresent: true) // Disposable fixture value, never a live pairing PIN.
        waitForText(app,"tv.pair.pin","000000")
        let submit = element(app, "tv.pair.submit")
        XCTAssertFalse(submit.isEnabled,"A complete code cannot enable pairing to a public address")
        XCTAssertTrue(element(app, "tv.pair.address").exists, "Invalid public address must not commit pairing")
        element(app,"tv.pair.cancel").tap()
        XCTAssertTrue(element(app,"tv.connect").waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields.matching(identifier: "tv.pair.address").count,0)
        openConnect(app,fromTVPanel: true)
        XCTAssertTrue(element(app, "tv.pair.submit").exists)
        element(app,"tv.pair.cancel").tap()
    }

    @MainActor func testEpisodeWindowTitlesRangesWatchedAndNamedMiruroSources() {
        let app = launch(), continuing = element(app,"row.continue")
        XCTAssertTrue(continuing.waitForExistence(timeout: 5))
        let first = cards(continuing).first; XCTAssertNotNil(first); first!.tap()
        XCTAssertTrue(element(app,"destination.here").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app,"destination.website").isHittable,"The website fallback must precede the long episode inventory")
        let page = element(app,"screen.episode"), window = element(app,"episodes.list")
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(window.frame.height,0); XCTAssertLessThan(window.frame.height,app.frame.height * 0.6,"1140 rows must stay inside a bounded window")
        // Begin on real page content above the nested list. Keep both
        // endpoints clear of transparent edge padding and the Home indicator,
        // which consumed the old x399/y849 gesture without scrolling at all.
        for _ in 0..<4 {
            let viewport = page.frame.intersection(app.frame)
            if viewport.insetBy(dx: -1,dy: -1).contains(window.frame) { break }
            let origin = app.coordinate(withNormalizedOffset: .zero), x = viewport.midX - app.frame.minX
            let startY = max(viewport.minY + 60,min(viewport.minY + viewport.height * 0.65,window.frame.minY - 32))
            origin.withOffset(CGVector(dx: x,dy: startY - app.frame.minY)).press(forDuration: 0.05,thenDragTo: origin.withOffset(CGVector(dx: x,dy: viewport.minY - app.frame.minY + viewport.height * 0.15)))
        }
        XCTAssertTrue(page.frame.intersection(app.frame).insetBy(dx: -1,dy: -1).contains(window.frame))
        func jump(_ label: String,_ id: String) {
            element(app,"episodes.ranges").tap()
            let range = app.buttons[label].firstMatch; XCTAssertTrue(range.waitForExistence(timeout: 4)); range.tap()
            let target = element(app,"episode.choice." + id)
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [reached],timeout: 6),.completed)
        }
        jump("1101–1140","1101")
        XCTAssertTrue(element(app,"episode.choice.1101").label.contains("Fixture episode 1101"),"Actual supplied titles must survive a far-range jump")
        element(app,"episodes.current").tap()
        let current = element(app,"episode.choice.6")
        let currentReached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [currentReached],timeout: 6),.completed)
        let savedProgress = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@","Current episode, 14% watched"),object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [savedProgress],timeout: 8),.completed,"The selected episode shows its own saved progress")
        jump("1–100","1")
        let watched = element(app,"episode.choice.1")
        XCTAssertEqual(watched.value as? String,"Watched"); watched.tap()
        let selectedWatched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@","Current episode","Watched"),object: watched)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedWatched],timeout: 6),.completed,"Current and Watched are separate states")
        let source = element(app,"sources.choice.provider")
        XCTAssertTrue(source.waitForExistence(timeout: 5)); source.tap()
        let named = app.buttons["Fixture B"].firstMatch; XCTAssertTrue(named.waitForExistence(timeout: 4)); named.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label CONTAINS %@","Fixture B","Fixture B"),object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen],timeout: 6),.completed,"The picker must use the real website choice label")
        screenshot(app,"fixture-episode-window-and-named-source")
        select(app,"home")
    }

    @MainActor func testStandaloneMutedNativeFrameSubtitlesAndClose() {
        executionTimeAllowance = 300
        let app = launch("--qa-tv-unpaired")
        let row = element(app, "row.continue")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let card = cards(row).first
        XCTAssertNotNil(card); card!.tap()
        let here = element(app, "destination.here")
        XCTAssertTrue(here.waitForExistence(timeout: 5))
        let fallback = element(app,"destination.website")
        XCTAssertTrue(fallback.exists && fallback.isHittable,"Website playback must be available before scrolling a long episode grid")
        here.tap()
        let frameReady = element(app, "qa.player.ready")
        XCTAssertTrue(frameReady.waitForExistence(timeout: 5))
        let decodedFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "ready"), object: frameReady)
        XCTAssertEqual(XCTWaiter.wait(for: [decodedFrame], timeout: 45), .completed, "Play here must open the first ranked stream directly and decode a frame")
        let time = element(app,"qa.player.time")
        XCTAssertTrue(time.waitForExistence(timeout: 4))
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { item,_ in
            guard let marker = item as? XCUIElement, let text = marker.value as? String, let seconds = Double(text) else { return false }
            return seconds >= 2
        },object: time)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing],timeout: 20),.completed,"Decoded playback must actually advance, not remain on its first frame")
        // The stable transition witness coordinates the check without polling
        // cached, changing clock values. The actual frame/advancement gates
        // above and zero rendered buttons below remain independent assertions.
        let hiddenControls = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@","qa.player.controls","Controls hidden")).firstMatch
        XCTAssertTrue(hiddenControls.waitForExistence(timeout: 8),"The playing player must complete its actual control-hide transition")
        // The recorded controls were absent, but a missing-ID AX lookup took
        // 7.3s and raced an 8s predicate timer. Keep the exact zero result while
        // performing that single lookup outside a competing expectation timer.
        XCTAssertEqual(app.buttons.matching(identifier: "player.subtitles").count,0,"Controls must actually leave accessibility after the playback idle window")
        screenshot(app, "fixture-native-decoded-frame")

        let viewport = app.frame
        let videoPoint = videoTapPoint(app,viewport: viewport)
        let cachedPause = app.staticTexts.matching(identifier: "qa.player.pause-point").firstMatch
        let coordinates = (cachedPause.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        guard coordinates.count == 2, coordinates.allSatisfy(\.isFinite) else {
            XCTFail("Requires the actual Play/Pause hit point from before the controls hid")
            return
        }
        let pausePoint = CGPoint(x: CGFloat(coordinates[0]),y: CGFloat(coordinates[1]))
        let pauseTap = playerCoordinate(app,at: pausePoint,viewport: viewport)
        // A slow accessibility query can outlast the playing controls' reveal
        // window. Tap the video and its now-visible pause button consecutively.
        videoPoint.tap()
        pauseTap.tap()
        let playPause = element(app,"player.play-pause")
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@","Play"),object: playPause)
        XCTAssertEqual(XCTWaiter.wait(for: [paused],timeout: 8),.completed,"The video tap must reveal an actionable control that pauses the actual player")
        XCTAssertTrue(playPause.frame.insetBy(dx: -1,dy: -1).contains(pausePoint),"The cached touch must hit the actual playback button")
        videoPoint.tap()
        XCTAssertTrue(hiddenControls.waitForExistence(timeout: 6),"A video tap must hide the controls while playback is paused")
        XCTAssertEqual(app.buttons.matching(identifier: "player.subtitles").count,0)
        videoPoint.tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 6))
        XCTAssertEqual(playPause.label,"Play","Showing controls again must leave playback paused")
        element(app, "player.subtitles").tap()
        let settings = element(app, "player.subtitle.settings")
        let fixtureTrack = element(app,"player.subtitle.track.0")
        XCTAssertTrue(fixtureTrack.waitForExistence(timeout: 6)); fixtureTrack.tap()
        element(app,"player.subtitle.done").tap()
        let caption = element(app, "player.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 6))
        XCTAssertEqual(caption.label,"QA external VTT caption")
        XCTAssertFalse(caption.frame.intersection(app.frame).isEmpty)
        assertNativeCaptionAndTransportFit(app,caption: caption)
        let beforeSeek = Double(time.value as? String ?? "") ?? -1
        let timeline = element(app,"player.timeline")
        timeline.adjust(toNormalizedSliderPosition: 0.02)
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { item,_ in
            guard let marker = item as? XCUIElement, let value = marker.value as? String, let at = Double(value) else { return false }
            return beforeSeek >= 0 && abs(at - beforeSeek) >= 2
        },object: time)
        XCTAssertEqual(XCTWaiter.wait(for: [sought],timeout: 12),.completed,"Paused slider interaction must move actual AVPlayer time")
        XCTAssertEqual(playPause.label,"Play","A paused seek must not resume or claim playback")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in app.frame.width > app.frame.height },object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape],timeout: 6),.completed)
        assertNativeCaptionAndTransportFit(app,caption: caption)
        screenshot(app,"fixture-native-landscape-caption-and-dock")
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in app.frame.height > app.frame.width },object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait],timeout: 6),.completed)
        assertNativeCaptionAndTransportFit(app,caption: caption)
        let originalCaptionFrame = caption.frame
        screenshot(app, "fixture-external-vtt-rendered")
        element(app, "player.subtitles").tap()
        for id in ["player.subtitle.larger", "player.subtitle.raise"] {
            let action = element(app, id)
            XCTAssertTrue(action.waitForExistence(timeout: 3)); expose(action,in: settings); action.tap()
        }
        element(app,"player.subtitle.done").tap()
        XCTAssertGreaterThanOrEqual(caption.frame.height,originalCaptionFrame.height)
        XCTAssertLessThan(caption.frame.maxY,originalCaptionFrame.maxY, "Raise must move the actual caption, not just accept a button tap")
        screenshot(app, "fixture-external-vtt-resized-and-raised")
        element(app, "player.subtitles").tap()
        let off = element(app, "player.subtitle.off")
        for _ in 0..<4 { if off.isHittable { break }; settings.swipeDown() }
        XCTAssertTrue(off.isHittable); off.tap(); element(app,"player.subtitle.done").tap()
        let captionOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR label == ''"),object: caption)
        XCTAssertEqual(XCTWaiter.wait(for: [captionOff],timeout: 4),.completed)
        let portraitViewport = app.frame
        let revealForClose = videoTapPoint(app,viewport: portraitViewport)
        let closeFrame = element(app,"player.close").frame
        XCTAssertFalse(closeFrame.isEmpty,"Back must remain reachable while paused")
        let closeTap = playerCoordinate(app,at: CGPoint(x: closeFrame.midX,y: closeFrame.midY),viewport: portraitViewport)
        let beforeResume = Double(time.value as? String ?? "") ?? -1
        playPause.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { item,_ in
            guard let marker = item as? XCUIElement, let value = marker.value as? String, let at = Double(value) else { return false }
            return beforeResume >= 0 && at >= beforeResume + 1
        },object: time)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed],timeout: 12),.completed,"The custom Play control must resume actual decoded playback after the seek")
        XCTAssertTrue(hiddenControls.waitForExistence(timeout: 8),"Wait for auto-hide before tapping to reveal the close button")
        revealForClose.tap()
        closeTap.tap()
        gone(element(app, "qa.player.ready"))
        XCTAssertTrue(element(app, "nav.toggle").waitForExistence(timeout: 5))
    }

    /// Live public WK extraction, while account/dashboard/TV services remain fake.
    /// Fake Continue cards are deliberately excluded from the positive proof.
    @MainActor func testLiveMiruroCatalogueHeroAndSearchExtraction() {
        let app = launch("--qa-live-provider")
        let realCards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "card.https://miruro.", "card.https://www.miruro."))
        XCTAssertTrue(element(app, "home.hero").waitForExistence(timeout: 60), "Requires a real public featured hero")
        assertHeaderFits(app)
        screenshot(app,"live-miruro-home")
        for _ in 0..<4 {
            if realCards.firstMatch.exists { break }
            element(app,"screen.home").swipeUp()
        }
        XCTAssertTrue(realCards.firstMatch.waitForExistence(timeout: 60), "Requires real provider URL cards; fake signed-in Continue cards are not evidence of extraction")
        let firstID = realCards.firstMatch.identifier
        let realRow = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@","row.")).containing(.button,identifier: firstID).firstMatch
        XCTAssertTrue(realRow.exists)
        let firstThree = cards(realRow).prefix(3)
        let contentViewport = element(app,"screen.home").frame.intersection(app.frame)
        XCTAssertEqual(firstThree.count,3,"Requires three real provider posters")
        for _ in 0..<3 {
            if firstThree.allSatisfy({ fullyVisible($0,in: realRow,app: app,contentViewport: contentViewport) }) { break }
            element(app,"screen.home").swipeUp()
        }
        for card in firstThree { XCTAssertTrue(fullyVisible(card,in: realRow,app: app,contentViewport: contentViewport),"Real artwork must retain three complete portrait posters") }
        assertHeaderFits(app)
        screenshot(app,"live-miruro-three-complete-posters")
        _ = openNavigation(app)
        screenshot(app, "live-miruro-expanded-sidebar")
        gone(element(app,"nav.pane"),timeout: 8) // Let the real idle timer close this captured pane before reopening for Search.
        tapNavigation(app,"search")
        XCTAssertTrue(element(app, "screen.search").waitForExistence(timeout: 5))
        setText(app, "search.field", "One Piece",replacing: ""); element(app, "search.submit").tap()
        let positive = app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS[c] %@", "card.https://miruro.", "card.https://www.miruro.", "One Piece")).firstMatch
        XCTAssertTrue(positive.waitForExistence(timeout: 45), "Requires actual public search results for One Piece")
        screenshot(app, "live-miruro-positive-search")
    }
}
