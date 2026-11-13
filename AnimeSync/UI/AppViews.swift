import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 0.035,green: 0.035,blue: 0.065)
    static let surface = Color(red: 0.10,green: 0.10,blue: 0.16)
    static let accent = Color(red: 0.72,green: 0.92,blue: 0.85)
}
struct SwipeExclusions: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect],nextValue: () -> [CGRect]) { value += nextValue() }
}
extension View {
    func keepHorizontalGesture() -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: SwipeExclusions.self,value: [geometry.frame(in: .named("page"))]) })
    }
}

struct AppRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var exclusions: [CGRect] = []
    var body: some View {
        GeometryReader { geometry in
            scene(available: geometry.size)
            .coordinateSpace(name: "page")
            .onPreferenceChange(SwipeExclusions.self) { exclusions = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 24,coordinateSpace: .named("page")).onEnded { value in
                backSwipe(value,pageWidth: geometry.size.width,windowOrigin: geometry.frame(in: .global).origin)
            })
        }
        .sheet(isPresented: Binding(get: { model.tvPanel && model.player == nil },set: { model.tvPanel = $0 })) { TVPanel(model: model) }
        .sheet(isPresented: Binding(get: { model.pairingSheet && !model.tvPanel },set: { model.pairingSheet = $0 }),onDismiss: { model.tv.cancelPairing(); model.discovery.stop() }) { PairingScreen(model: model) }
        .fullScreenCover(item: $model.player,onDismiss: { Task { await model.playerCoverDismissed() } },content: playerView)
        .modifier(TakeoverAlert(model: model,enabled: !model.tvPanel && model.player == nil))
        .overlay(alignment: .bottom) {
            AppNotice(model: model)
        }
        .task(id: showingContinueWatching) {
            guard showingContinueWatching else { return }
            await model.sync.pollContinueWatching()
        }
        .onChange(of: model.provider.sources) { _,_ in model.launchIfReady() }
        .onChange(of: model.provider.metadata) { _,_ in model.launchIfReady() }
        .onChange(of: scenePhase) { _,phase in Task { if phase == .active { await model.foreground() } else if phase == .background { await model.background() } } }
    }
    private var showingContinueWatching: Bool {
        scenePhase == .active && model.route == .home && model.sync.isSignedIn &&
            model.player == nil && !model.signingIn && !model.tvPanel && !model.pairingSheet
    }
    private func scene(available: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()
            webDocuments
            nativeContent.frame(width: available.width,alignment: .topLeading)
            if model.drawer {
                // Keep the logo reachable while the content scrim closes the pane.
                Color.black.opacity(0.22).onTapGesture { model.drawer = false }.padding(.top,64).ignoresSafeArea(edges: .bottom)
                SidebarPane(model: model,available: available).padding(.top,64).padding(.leading,8)
            }
        }
    }
    private var webDocuments: some View {
        Group {
            // Keep documents alive while native controls own input/accessibility.
            ProviderWebView(provider: model.provider,visible: model.route.website && !showDashboard).opacity(model.route.website && !showDashboard ? 1 : 0.001).allowsHitTesting(model.route.website && !showDashboard).accessibilityHidden(!model.route.website || showDashboard).padding(.top,64)
            DashboardWebView(dashboard: model.dashboard,visible: showDashboard).opacity(showDashboard ? 1 : 0.001).allowsHitTesting(showDashboard).accessibilityHidden(!showDashboard).padding(.top,64)
        }
    }
    private var nativeContent: some View {
        VStack(spacing: 0) {
            topBar
            if !model.route.website && !showDashboard { page.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top) }
            else { Color.clear.allowsHitTesting(false) }
        }
    }
    private func backSwipe(_ value: DragGesture.Value,pageWidth: CGFloat,windowOrigin: CGPoint) {
        let leftwardDistance = -value.translation.width
        let startsAtRightEdge = value.startLocation.x >= pageWidth - 20
        guard leftwardDistance > 96, leftwardDistance > abs(value.translation.height) * 2,
              startsAtRightEdge || !exclusions.contains(where: { $0.contains(value.startLocation) }) else { return }
        let expectedRoute = model.route, expectedSignIn = model.signingIn
        Task { @MainActor in
            if !startsAtRightEdge && !model.drawer {
                let windowPoint = CGPoint(x: windowOrigin.x + value.startLocation.x,y: windowOrigin.y + value.startLocation.y)
                if showDashboard {
                    let view = model.dashboard.webView
                    guard view.window != nil, await model.dashboard.allowsBackSwipe(at: view.convert(windowPoint,from: nil)) else { return }
                } else if model.route.website {
                    let view = model.provider.webView
                    guard view.window != nil, await model.provider.allowsBackSwipe(at: view.convert(windowPoint,from: nil)) else { return }
                }
            }
            guard model.route == expectedRoute, model.signingIn == expectedSignIn,
                  model.player == nil, !model.tvPanel, !model.pairingSheet else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to: nil,from: nil,for: nil)
            await model.back()
        }
    }
    private func playerView(_ player: NativePlaybackModel) -> some View {
        NativePlayerScreen(model: player,onTV: { model.playOnTV() },tvPanelPresented: model.tvPanel)
            .sheet(isPresented: $model.tvPanel) { TVPanel(model: model) }
            .modifier(TakeoverAlert(model: model,enabled: !model.tvPanel))
            .overlay(alignment: .bottom) { AppNotice(model: model) }
    }
    private var showDashboard: Bool { model.signingIn || model.route.section == "Anime Sync" && !model.dashboard.authenticated }
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { model.toggleDrawer() } label: { Image("miruro-logo").resizable().scaledToFit().frame(width: 32,height: 32).frame(width: 48,height: 48) }
                .accessibilityLabel(model.drawer ? "Close menu" : "Open menu").accessibilityIdentifier("nav.toggle")
            Text(model.route.section == "Episode" ? "Miruro" : model.route.section).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Button { model.navigate("Search") } label: { Image(systemName: "magnifyingglass").frame(width: 36,height: 44) }.accessibilityLabel("Search")
            Button { model.tvPanel = true } label: { HStack(spacing: 7) { Image("tv-connect").resizable().renderingMode(.template).scaledToFit().frame(width: 20,height: 20); Text(model.tv.state.paired && model.tv.state.online ? "TV" : "Connect") }.font(.subheadline.weight(.medium)).padding(.horizontal,12).padding(.vertical,9).background(Theme.surface,in: Capsule()) }.accessibilityLabel("TV controls").accessibilityIdentifier("tv.pill")
        }.padding(.horizontal,10).frame(height: 64).background(Theme.background.opacity(0.94))
    }
    @ViewBuilder private var page: some View {
        switch model.route.section {
        case "Settings": AppSettings(model: model)
        case "Anime Sync": LibraryScreen(model: model)
        case "History": HistoryScreen(model: model)
        case "Episode": EpisodeScreen(model: model)
        default: CatalogueScreen(model: model)
        }
    }
}

struct SidebarPane: View {
    @ObservedObject var model: AppModel
    var available: CGSize
    static let entries: [(String,String,String)] = [
        ("Home","home","home"),("Trending","trending","trending"),("Discover","discover","discover"),("Search","search","search"),
        ("Schedule","schedule","schedule"),("History","history","history"),("Announcements","announcements","announcements"),("Profile","profile","profile"),
        ("Anime Sync","anime-sync","profile"),("TV","tv","tv"),("Settings","settings","settings"),("Login","login","login")]
    private var width: CGFloat {
        let font = UIFont.systemFont(ofSize: 14,weight: .medium)
        let widest = Self.entries.map { ($0.0 as NSString).size(withAttributes: [.font:font]).width }.max() ?? 100
        // Icon24 + one gap14 + row insets28 + pane insets12, with4pt
        // rounding slack. A trailing Spacer used to add an uncounted gap.
        return max(1,min(available.width - 32,ceil(widest) + 24 + 14 + 28 + 12 + 4))
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Self.entries,id: \.1) { title,key,icon in
                    Button { model.navigate(title) } label: {
                        HStack(spacing: 14) {
                            if title == "Anime Sync" { Image("anime-sync-logo").resizable().scaledToFit().frame(width: 22,height: 22) }
                            else if title == "TV" { Image(systemName: "tv").font(.system(size: 21)).frame(width: 24) }
                            else { Image("miruro-" + icon).resizable().renderingMode(.template).scaledToFit().frame(width: 24,height: 24) }
                            Text(title).font(.system(size: 14,weight: .medium)).lineLimit(1).fixedSize(horizontal: true,vertical: false)
                        }.frame(maxWidth: .infinity,alignment: .leading).foregroundStyle(model.route.section == title ? Theme.background : .white.opacity(0.9)).padding(.horizontal,14).frame(height: 48)
                            .background(model.route.section == title ? Color(red: 0.81,green: 0.85,blue: 0.97) : .clear,in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("nav.item." + key)
                }
            }.padding(6)
        }.frame(width: width,height: min(612,max(120,available.height - 82)))
            .background(.ultraThinMaterial,in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.5),radius: 20).accessibilityIdentifier("nav.pane")
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in model.touchDrawer() })
    }
}

struct Poster: View {
    var title: String; var url: URL?; var badge = ""; var width: CGFloat; var identifier: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading,spacing: 7) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.white.opacity(0.25)) }
                    if !badge.isEmpty { Text(badge).font(.system(size: 10,weight: .semibold)).padding(5).background(.black.opacity(0.8),in: Capsule()).padding(5) }
                }.frame(width: width,height: width * 1.42).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title).font(.system(size: 12,weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(2).frame(height: 32,alignment: .topLeading)
            }.frame(width: width)
        }.buttonStyle(.plain).accessibilityLabel(title + (badge.isEmpty ? "" : ", " + badge)).accessibilityIdentifier("card." + identifier)
    }
}
struct PosterRow<Content: View>: View {
    var title: String; var identifier: String; var viewportWidth: CGFloat; @ViewBuilder var content: (CGFloat) -> Content
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal,16)
            ScrollView(.horizontal) { HStack(alignment: .top,spacing: 12) { content(viewportWidth < 600 ? max(1,floor((viewportWidth - 56) / 3)) : 154) }.padding(.horizontal,16) }.scrollIndicators(.hidden).accessibilityIdentifier(identifier).keepHorizontalGesture()
        }.frame(width: viewportWidth,alignment: .leading)
    }
}
struct HeroView: View {
    let hero: CatalogueHero; var viewportWidth: CGFloat; var action: () -> Void
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: hero.backdropURL) { image in image.resizable().scaledToFill() } placeholder: { LinearGradient(colors: [.indigo.opacity(0.7),Theme.background],startPoint: .topTrailing,endPoint: .bottomLeading) }.frame(width: viewportWidth,height: 300).clipped()
            LinearGradient(colors: [.clear,Theme.background.opacity(0.96)],startPoint: .top,endPoint: .bottom)
            VStack(alignment: .leading,spacing: 10) {
                Text("FEATURED").font(.caption2.weight(.bold)).tracking(3).foregroundStyle(Theme.accent)
                Text(hero.title).font(.system(size: 28,weight: .bold)).lineLimit(2)
                if !hero.meta.isEmpty { Text(hero.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(hero.description).font(.caption).lineLimit(2).foregroundStyle(.white.opacity(0.75))
                if hero.url != nil { Button(action: action) { Label("Watch now",systemImage: "play.fill").font(.subheadline.weight(.semibold)).padding(.horizontal,18).padding(.vertical,10).background(Theme.accent,in: Capsule()).foregroundStyle(Theme.background) } }
            }.padding(20)
        }.frame(width: viewportWidth,height: 300).clipped().accessibilityIdentifier("home.hero")
    }
}

/// Anime Sync owns the Home continuation row and the separate native History.
/// Suppress only those exact provider-heading aliases; catalogue sections such
/// as "Continue Watching Classics" remain ordinary provider content.
enum CataloguePresentation {
    static func groups(_ groups: [CatalogueGroup],section: String) -> [CatalogueGroup] {
        guard section == "Home" else { return groups }
        return groups.filter { group in
            let heading = group.title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { String($0) }.joined()
            return heading != "continuewatching" && heading != "recentlywatched"
        }
    }
}

struct CatalogueScreen: View {
    @ObservedObject var model: AppModel
    private var groups: [CatalogueGroup] { CataloguePresentation.groups(model.provider.groups,section: model.route.section) }
    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                if model.route.section == "Search" { searchBar.padding(.horizontal,16).padding(.top,12) }
                if model.route.section == "Home", let hero = model.provider.hero { HeroView(hero: hero,viewportWidth: viewport.size.width) { if let url = hero.url { model.open(url) } } }
                if model.route.section == "Home", !model.sync.history.continuing.isEmpty {
                    PosterRow(title: "Continue Watching",identifier: "row.continue",viewportWidth: viewport.size.width) { width in
                        ForEach(model.sync.history.continuing) { card in Poster(title: card.title,url: model.fixture ? nil : card.posterURL,badge: "Episode " + card.episode,width: width,identifier: card.id) { Task { await model.continueWatching(card) } } }
                    }
                }
                ForEach(groups) { group in
                    PosterRow(title: group.title,identifier: "row." + group.title.lowercased(),viewportWidth: viewport.size.width) { width in ForEach(group.items) { card in Poster(title: card.title,url: card.posterURL,badge: card.badge,width: width,identifier: card.id) { model.open(card.url) } } }
                }
                if model.provider.loading { ProgressView("Loading Miruro…").frame(maxWidth: .infinity).padding(30) }
                if let error = model.provider.error { empty(error,button: "Try again") { Task { await model.retryConnection() } } }
                else if !model.provider.loading && groups.isEmpty && model.provider.hero == nil && !(model.route.section == "Home" && !model.sync.history.continuing.isEmpty) {
                    empty(model.provider.emptyMessage,button: "Open website") { model.website() }.accessibilityIdentifier("search.empty")
                }
            }.frame(width: viewport.size.width,alignment: .leading).padding(.bottom,28)
        }.scrollDismissesKeyboard(.interactively).refreshable { await model.retryConnection() }
            .frame(width: viewport.size.width)
            .accessibilityIdentifier("screen." + model.route.section.lowercased())
        }
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search anime",text: $model.searchText).submitLabel(.search).autocorrectionDisabled().onSubmit { model.search() }.accessibilityIdentifier("search.field")
            Button { model.search() } label: { Image(systemName: "arrow.right").font(.system(size: 16,weight: .semibold)).frame(width: 34,height: 34).background(.white.opacity(0.1),in: Circle()) }.accessibilityLabel("Search").accessibilityIdentifier("search.submit")
        }.padding(12).background(Theme.surface,in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08))).keepHorizontalGesture()
    }
}

struct HistoryScreen: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            VStack(spacing: 24) {
                if model.sync.history.recent.isEmpty { empty(model.sync.isSignedIn ? "Nothing watched yet" : "Sign in to see your history",button: "Anime Sync") { model.navigate("Anime Sync") } }
                else { PosterRow(title: "Recently Watched",identifier: "row.history",viewportWidth: viewport.size.width) { width in ForEach(model.sync.history.recent) { entry in Poster(title: entry.title,url: model.fixture ? nil : entry.posterURL,badge: "Episode " + entry.episode,width: width,identifier: entry.id) { model.open(entry.watchURL ?? entry.resolverURL) } } } }
            }.frame(width: viewport.size.width).padding(.top,20)
        }.frame(width: viewport.size.width).refreshable { await model.sync.refreshHistory() }.accessibilityIdentifier("screen.history")
        }
    }
}
struct LibraryScreen: View {
    @ObservedObject var model: AppModel
    private var cards: [SyncLibraryCard] { model.dashboard.libraryCards.filter { card in (model.libraryFilter == "all" || model.libraryFilter == "continue" && card.continuing || model.libraryFilter == "new" && card.hasNew) && (model.libraryQuery.isEmpty || card.title.localizedCaseInsensitiveContains(model.libraryQuery)) } }
    var body: some View {
        GeometryReader { viewport in library(width: viewport.size.width) }
    }
    private func library(width: CGFloat) -> some View {
        let contentWidth = max(1,width - 32)
        let columnCount = width < 600 ? 3 : max(3,Int(contentWidth / 148))
        let cardWidth = max(1,(contentWidth - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount))
        let columns = Array(repeating: GridItem(.fixed(cardWidth),spacing: 12,alignment: .top),count: columnCount)
        return ScrollView {
            VStack(alignment: .leading,spacing: 20) {
                HStack { Image("anime-sync-logo").resizable().frame(width: 44,height: 44); VStack(alignment: .leading) { Text("Your library").font(.title2.bold()); Text(model.sync.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer() }.padding(.top,12)
                if model.sync.historyRefreshFailed || model.dashboard.error != nil {
                    Button("Try again") { Task { await model.retryConnection() } }.font(.footnote)
                }
                TextField("Search your library",text: $model.libraryQuery).textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityIdentifier("library.search").keepHorizontalGesture()
                HStack { filter("Continue","continue"); filter("New episodes","new"); filter("All anime","all") }
                LazyVGrid(columns: columns,alignment: .leading,spacing: 22) {
                    ForEach(cards) { card in Poster(title: card.title,url: model.fixture ? nil : card.posterURL,badge: "Episode " + card.episode,width: cardWidth,identifier: card.id) { Task { await model.openLibraryCard(card) } } }
                }
                if cards.isEmpty {
                    if model.dashboard.loading { ProgressView("Loading library…").frame(maxWidth: .infinity).padding(30) }
                    else { Text("No anime in this view.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30) }
                }
                Button("Open full dashboard") { model.signIn() }.font(.footnote)
            }.frame(width: contentWidth,alignment: .leading).padding(.horizontal,16).padding(.bottom,30)
        }.frame(width: width).scrollDismissesKeyboard(.interactively).refreshable { await model.retryConnection() }.accessibilityIdentifier("screen.anime-sync")
    }
    private func filter(_ title: String,_ id: String) -> some View { Button(title) { model.libraryFilter = id }.font(.caption.weight(.semibold)).padding(.horizontal,12).padding(.vertical,10).background(model.libraryFilter == id ? Theme.accent.opacity(0.2) : Theme.surface,in: Capsule()).accessibilityIdentifier("library.filter." + id) }
}

struct EpisodeJumpRange: Identifiable, Equatable {
    let id: Int
    let label: String
    let firstEpisodeID: String
}
enum EpisodePresentation {
    private static func decimal(_ text: String) -> Decimal? {
        guard text.range(of: "^[0-9]+(?:\\.[0-9]+)?\\z",options: .regularExpression) != nil else { return nil }
        return Decimal(string: text,locale: Locale(identifier: "en_US_POSIX"))
    }
    static func number(_ episode: EpisodeChoice) -> String {
        let raw = episode.number.isEmpty ? episode.id : episode.number
        return decimal(raw).map { NSDecimalNumber(decimal: $0).stringValue } ?? episode.number
    }
    static func ordered(_ episodes: [EpisodeChoice]) -> [EpisodeChoice] {
        var seen = Set<String>()
        return episodes.enumerated().filter { !$0.element.id.isEmpty && seen.insert($0.element.id).inserted }.sorted { lhs,rhs in
            let left = decimal(number(lhs.element)), right = decimal(number(rhs.element))
            if let left, let right, left != right { return left < right }
            if left != nil && right == nil { return true }
            if left == nil && right != nil { return false }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
    static func isCurrent(_ episode: EpisodeChoice,number current: String) -> Bool {
        if let selected = decimal(current) { return decimal(number(episode)).map { selected == $0 } ?? false }
        return episode.selected
    }
    static func title(_ episode: EpisodeChoice) -> String {
        let supplied = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty { return supplied }
        let value = number(episode)
        return value.isEmpty ? episode.label : "Episode " + value
    }
    static func jumps(_ episodes: [EpisodeChoice]) -> [EpisodeJumpRange] {
        var groups: [Int:[EpisodeChoice]] = [:]
        for episode in ordered(episodes) {
            guard let value = decimal(number(episode)) else { continue }
            var quotient = max(0,(value - 1) / 100), rounded = Decimal()
            NSDecimalRound(&rounded,&quotient,0,.down)
            guard let bucket = Int(NSDecimalNumber(decimal: rounded).stringValue) else { continue }
            groups[bucket,default: []].append(episode)
        }
        return groups.keys.sorted().compactMap { bucket in
            guard let first = groups[bucket]?.first, let last = groups[bucket]?.last else { return nil }
            let start = number(first), end = number(last)
            return EpisodeJumpRange(id: bucket,label: start == end ? start : start + "–" + end,firstEpisodeID: first.id)
        }
    }
    static func windowHeight(available: CGFloat) -> CGFloat { max(1,min(320,max(150,available * 0.42),max(1,available - 24))) }
}

struct EpisodeWindow: View {
    let episodes: [EpisodeChoice]
    let currentNumber: String
    let complete: Bool
    let height: CGFloat
    let select: (String) -> Void
    var isWatched: (EpisodeChoice) -> Bool = { _ in false }
    var currentProgress: Double? = nil
    private var currentID: String? { episodes.first { EpisodePresentation.isCurrent($0,number: currentNumber) }?.id }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading,spacing: 12) {
                HStack {
                    VStack(alignment: .leading,spacing: 3) { Text("Episodes").font(.headline); Text("\(episodes.count)" + (complete ? " episodes" : " available episodes")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let currentID {
                        Button { withAnimation { proxy.scrollTo(currentID,anchor: .center) } } label: { Label("Current",systemImage: "location") }
                            .font(.caption).accessibilityIdentifier("episodes.current")
                    }
                }
                let ranges = EpisodePresentation.jumps(episodes)
                if ranges.count > 1 {
                    Menu { ForEach(ranges) { range in Button(range.label) { withAnimation { proxy.scrollTo(range.firstEpisodeID,anchor: .top) } } } }
                        label: { Label("Jump to episode range",systemImage: "list.number").font(.subheadline) }
                        .accessibilityIdentifier("episodes.ranges")
                }
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(episodes) { episode in row(episode) }
                    }.padding(6)
                }.frame(height: height).background(Theme.surface.opacity(0.55),in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("episodes.list")
                if !complete { Text("Miruro has shared this part of the episode list. More episodes may be available on the website.").font(.caption).foregroundStyle(.secondary) }
            }
            .task(id: currentID) {
                guard let currentID else { return }; await Task.yield()
                guard !Task.isCancelled else { return }; proxy.scrollTo(currentID,anchor: .center)
            }
        }
    }
    private func row(_ episode: EpisodeChoice) -> some View {
        let selected = EpisodePresentation.isCurrent(episode,number: currentNumber), number = EpisodePresentation.number(episode), watched = isWatched(episode)
        let progress = selected ? currentProgress : nil
        let watchedPercent = progress.map { "\(Int(($0 * 100).rounded()))% watched" }
        return Button { select(episode.id) } label: {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    if !number.isEmpty { Text(number).font(.caption.weight(.semibold)).monospacedDigit().frame(minWidth: 34).padding(.vertical,7).padding(.horizontal,5).background(.white.opacity(0.07),in: RoundedRectangle(cornerRadius: 7)) }
                    Text(EpisodePresentation.title(episode)).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity,alignment: .leading)
                    if watched { Label("Watched",systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.secondary) }
                    if selected { Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent) }
                }
                if let progress { ProgressView(value: progress).tint(Theme.accent).accessibilityHidden(true) }
            }.padding(.horizontal,10).padding(.vertical,10).frame(minHeight: 56)
                .background(selected ? Theme.accent.opacity(0.14) : .clear,in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white).id(episode.id)
            .accessibilityIdentifier("episode.choice." + episode.id)
            .accessibilityLabel((number.isEmpty ? "" : "Episode " + number + ", ") + EpisodePresentation.title(episode))
            .accessibilityValue([selected ? "Current episode" : nil,watched ? "Watched" : nil,watchedPercent].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MiruroSourceControls: View {
    @ObservedObject var model: AppModel
    private func choices(_ kind: String) -> [WebsiteSourceChoice] { model.provider.sourceChoices.filter { $0.kind == kind } }
    var body: some View {
        if !model.provider.sourceChoices.isEmpty || model.provider.sourceChoicesLoading {
            VStack(alignment: .leading,spacing: 10) {
                HStack { Text("Miruro sources").font(.headline); Spacer(); if model.provider.sourceChoicesLoading { ProgressView().controlSize(.small) } }
                ForEach(["audio","provider"],id: \.self) { kind in
                    let items = choices(kind)
                    if !items.isEmpty { picker(kind,items: items) }
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("sources.choices")
        }
    }
    private func picker(_ kind: String,items: [WebsiteSourceChoice]) -> some View {
        let selection = Binding<String>(get: { items.first(where: \.selected)?.id ?? "" },set: { if !$0.isEmpty { model.selectMiruroSource(id: $0) } })
        return Picker(kind == "audio" ? "Audio" : "Provider",selection: selection) {
            Text("Choose").tag("")
            ForEach(items) { choice in Text(choice.label).tag(choice.id) }
        }.pickerStyle(.menu).disabled(model.provider.sourceChoicesLoading).accessibilityIdentifier("sources.choice." + kind)
    }
}

struct EpisodeScreen: View {
    @ObservedObject var model: AppModel
    private var watchedScope: String { "\(model.sync.accountGeneration):\(model.provider.metadata?.site ?? ""):\(model.provider.metadata?.animeID ?? "")" }
    var body: some View {
        GeometryReader { viewport in content(episodeHeight: EpisodePresentation.windowHeight(available: viewport.size.height)) }
            .task(id: watchedScope) {
                guard model.sync.isSignedIn, model.provider.metadata?.isValid == true else { return }
                await model.sync.refreshHistory()
            }
    }
    private func content(episodeHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                if let metadata = model.provider.metadata {
                    HStack(alignment: .top,spacing: 18) {
                        AsyncImage(url: model.fixture ? nil : metadata.posterURL) { image in image.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius: 12).fill(Theme.surface).overlay(Image(systemName: "play.rectangle")) }.frame(width: 100,height: 142).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading,spacing: 12) {
                            Text(metadata.title).font(.title2.bold()).lineLimit(3)
                            Text("Episode " + metadata.episode).foregroundStyle(.secondary)
                            Text(model.sync.isSignedIn ? "Progress sync is on" : "Sign in to sync across devices").font(.caption).foregroundStyle(Theme.accent)
                            if !model.provider.synopsis.isEmpty { EpisodeSynopsis(text: model.provider.synopsis) }
                        }.frame(maxWidth: .infinity,alignment: .leading)
                    }
                    Button { Task { await model.playHere() } } label: { Label("Play here",systemImage: "play.fill").foregroundStyle(Theme.background).frame(maxWidth: .infinity).padding(14) }.buttonStyle(.borderedProminent).accessibilityIdentifier("destination.here")
                    if model.provider.sources.isEmpty { Text(model.provider.sourceStatus.rawValue).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("source.status") }
                    Button { model.playOnTV() } label: {
                        HStack(spacing: 8) {
                            Image(decorative: "tv-connect").resizable().renderingMode(.template).scaledToFit()
                                .frame(width: 20,height: 20)
                            Text("Play on TV")
                        }.frame(maxWidth: .infinity).padding(10)
                    }.buttonStyle(.bordered).accessibilityIdentifier("destination.tv")
                    websiteFallback
                    MiruroSourceControls(model: model)
                    if !model.provider.seasons.isEmpty {
                        seasons(model.provider.seasons)
                    }
                    if !model.provider.episodes.isEmpty {
                        EpisodeWindow(episodes: EpisodePresentation.ordered(model.provider.episodes),currentNumber: metadata.episode,
                                      complete: model.provider.episodeInventoryComplete,height: episodeHeight,select: { model.selectEpisode(id: $0) },
                                      isWatched: { model.sync.isEpisodeWatched(site: metadata.site,animeID: metadata.animeID,episode: EpisodePresentation.number($0)) },
                                      currentProgress: model.sync.episodeProgress(site: metadata.site,animeID: metadata.animeID,episode: metadata.episode))
                    }
                } else { ProgressView("Finding episode…").frame(maxWidth: .infinity).padding(30); websiteFallback }
                if let error = model.provider.error { Text(error).foregroundStyle(.secondary) }
                Text("Native playback supports HLS and MP4. Other formats and complex subtitle styling may need the website player.").font(.caption).foregroundStyle(.secondary)
                Button("Back") { Task { await model.back() } }
            }.padding(20)
        }.refreshable { await model.sync.refreshHistory() }.accessibilityIdentifier("screen.episode")
    }
    private var websiteFallback: some View {
        Button("Use website player") { model.website() }.buttonStyle(.bordered).padding(.vertical,4).accessibilityIdentifier("destination.website")
    }
    private func seasons(_ choices: [SeasonChoice]) -> some View {
        VStack(alignment: .leading,spacing: 10) {
            Text("Seasons").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(choices) { choice in
                        Button { model.selectSeason(id: choice.id) } label: {
                            ZStack(alignment: .bottomLeading) {
                                Theme.surface
                                AsyncImage(url: model.fixture ? nil : choice.posterURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: { Color.clear }
                                    .frame(width: 164,height: 96).clipped()
                                LinearGradient(colors: [.clear,.black.opacity(0.87)],startPoint: .top,endPoint: .bottom)
                                VStack(alignment: .leading,spacing: 4) {
                                    if choice.selected { Text("Current").font(.caption2.bold()).foregroundStyle(Theme.accent) }
                                    Text(choice.label).font(.subheadline.bold()).lineLimit(2)
                                    if !choice.year.isEmpty { Text(choice.year).font(.caption) }
                                }.padding(10)
                            }.frame(width: 164,height: 96).clipShape(.rect(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(choice.selected ? Theme.accent : .white.opacity(0.18)) }
                        }.buttonStyle(.plain).foregroundStyle(.white).disabled(choice.selected)
                            .accessibilityLabel(choice.title.isEmpty || choice.title == choice.label ? choice.label : "\(choice.label), \(choice.title)")
                            .accessibilityValue([choice.year,choice.selected ? "Current" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
                            .accessibilityAddTraits(choice.selected ? .isSelected : [])
                            .accessibilityIdentifier("season.choice." + choice.id)
                    }
                }
            }.scrollIndicators(.hidden).keepHorizontalGesture()
        }.accessibilityIdentifier("seasons.choices")
    }
}
private struct EpisodeSynopsis: View {
    let text: String
    @State private var contentHeight: CGFloat = 64
    #if DEBUG
    @State private var testScrollOffset: CGFloat = 0
    private let checkingScroll = ProcessInfo.processInfo.arguments.contains("--qa-episode-synopsis")
    #endif

    var body: some View {
        ScrollView {
            #if DEBUG
            if checkingScroll {
                synopsisText.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("synopsis.viewport")).minY } action: { testScrollOffset = $0 }
            } else { synopsisText }
            #else
            synopsisText
            #endif
        }
        .frame(height: min(64,contentHeight))
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.surface.opacity(0.55),in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityIdentifier("episode.synopsis")
        #if DEBUG
        .coordinateSpace(name: "synopsis.viewport")
        .overlay(alignment: .topLeading) {
            if checkingScroll {
                Text(String(Double(testScrollOffset))).font(.caption2).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("qa.synopsis.offset")
            }
        }
        #endif
    }

    private var synopsisText: some View {
        Text(verbatim: text)
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity,alignment: .leading)
            .padding(.vertical,6).padding(.horizontal,8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}
struct AppSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Anime Sync") {
                Text(model.sync.status)
                Button(model.sync.isSignedIn ? "Open account" : "Sign in") { model.signIn() }
                Button("Home server") { model.switchServer(AppWebPolicy.home) }
                Button("Tailscale server") { model.switchServer(AppWebPolicy.tailnet) }
                if model.sync.isSignedIn { Button("Sign out",role: .destructive) { Task { await model.signOut() } } }
            }
            Section("TV") { Button("TV controls") { model.tvPanel = true }; Button("Connect another TV") { model.pairingSheet = true }; if model.tv.state.paired { Button("Disconnect TV") { Task { await model.tv.disconnect() } } } }
            Section("Miruro") { Button("Website settings") { model.website(panel: "Settings") }; Button("Miruro account") { model.navigate("Login") } }
            Section("About") { Text("Anime Sync for iPhone · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")); Text("Miruro supplies the catalogue and streams. Anime Sync keeps your progress across devices. Native playback supports HLS/MP4 and readable text subtitles; protected or unsupported sources remain in the website player.").font(.footnote); Text("Away from home, connect Tailscale and select the Tailscale server. TV control needs the home subnet route.").font(.footnote) }
        }.accessibilityIdentifier("screen.settings")
    }
}
func empty(_ text: String,button: String,action: @escaping () -> Void) -> some View { VStack(spacing: 16) { Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary); Button(button,action: action).buttonStyle(.bordered) }.frame(maxWidth: .infinity).padding(30) }

struct AppNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let message = model.message {
            HStack { Text(message).font(.footnote); Spacer(); Button { model.message = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss message") }
                .padding(16).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 18)).padding(12)
        }
    }
}
