import SwiftUI

struct TVPanel: View {
    @ObservedObject var model: AppModel
    @State private var remote = false
    @State private var text = ""
    @State private var seek: Double = 0
    @State private var dragObservation: TVState?
    @State private var episodePresentation: TVEpisodePresentation?
    @State private var pendingEpisode: TVEpisodeIntent?
    private var state: TVState { model.tv.state }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    connection
                    timeline
                    transportControls
                    episodeActions
                    remoteControls
                    fixtureCounter
                }.padding(24)
            }
            .accessibilityIdentifier("tv.content")
            .background(Theme.background)
            .navigationTitle("Now on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { panelToolbar }
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
        .sheet(isPresented: $model.pairingSheet,onDismiss: { model.tv.cancelPairing(); model.discovery.stop() }) { PairingScreen(model: model) }
        .sheet(item: $episodePresentation,onDismiss: sendChosenEpisode) { presentation in
            TVEpisodePicker(observed: presentation.observed) { url in
                pendingEpisode = TVEpisodeIntent(observed: presentation.observed,url: url)
            }
        }
        .modifier(TakeoverAlert(model: model,enabled: true))
        .overlay(alignment: .bottom) { AppNotice(model: model) }
    }
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.12))
                Image(systemName: "tv").font(.title).foregroundStyle(Theme.accent)
            }.frame(width: 70,height: 70)
            VStack(alignment: .leading,spacing: 5) {
                Text(state.online ? state.title : "Your TV").font(.title3.bold()).lineLimit(2)
                Text(state.online ? state.episode : state.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(state.online ? Theme.accent : .gray).frame(width: 7,height: 7)
        }
    }
    @ViewBuilder private var connection: some View {
        if !state.paired || !state.online {
            Button("Connect TV") { model.pairingSheet = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("tv.connect")
        }
        Text(state.controlDescription).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity,alignment: .leading).accessibilityIdentifier("tv.control.status")
        if state.online && !state.control.mine {
            Button(state.control.available ? "Take control" : "Take over TV") { model.control { _ in } }
                .buttonStyle(.bordered).accessibilityIdentifier("tv.control.takeover")
        }
    }
    private var transportControls: some View {
        HStack(spacing: 30) {
            circle("gobackward.10","Back 10 seconds",size: 56) { model.send("seek",payload: ["seconds": .integer(-10)]) }
            circle(state.playing ? "pause.fill" : "play.fill","Play or pause TV",size: 76,primary: true) { model.send("toggle") }
                .accessibilityIdentifier("tv.playpause")
            circle("goforward.10","Forward 10 seconds",size: 56) { model.send("seek",payload: ["seconds": .integer(10)]) }
        }
    }
    @ViewBuilder private var episodeActions: some View {
        HStack {
            Button { pendingEpisode = nil; episodePresentation = TVEpisodePresentation(observed: state) } label: {
                Label("Episodes",systemImage: "list.bullet")
            }.disabled(state.watchURL == nil).accessibilityIdentifier("tv.episodes")
            Spacer()
            Button { model.send("subtitles") } label: { Label("Subtitles",systemImage: "captions.bubble") }
        }.buttonStyle(.bordered)
        if state.watchURL != nil {
            Button { model.moveFromTV() } label: { Label("Continue on this device",systemImage: "iphone.and.arrow.forward") }
                .font(.subheadline).buttonStyle(.bordered)
        }
    }
    private var remoteControls: some View {
        DisclosureGroup("Remote navigation",isExpanded: $remote) {
            VStack(spacing: 12) {
                HStack {
                    Button("TV Home") { model.send("home") }
                    Spacer()
                    Button("TV Back") { model.send("back") }
                }.buttonStyle(.bordered)
                arrowPad
                remoteText
                Button("Search / Enter") { key(66) }.buttonStyle(.bordered)
            }.padding(.top,14)
        }.tint(.white.opacity(0.8)).accessibilityIdentifier("tv.remote.expand")
    }
    private var arrowPad: some View {
        VStack(spacing: 6) {
            circle("chevron.up","Up",size: 54) { key(19) }
            HStack(spacing: 12) {
                circle("chevron.left","Left",size: 54) { key(21) }
                circle("circle.fill","Select",size: 62,primary: true) { key(23) }
                circle("chevron.right","Right",size: 54) { key(22) }
            }
            circle("chevron.down","Down",size: 54) { key(20) }
        }.padding(10)
    }
    private var remoteText: some View {
        HStack {
            TextField("Type on TV",text: $text).textFieldStyle(.roundedBorder)
            Button("Send") { model.send("text",payload: ["text": .string(String(text.prefix(2000)))]) }
        }
    }
    @ViewBuilder private var fixtureCounter: some View {
        #if DEBUG
        if let qa = model.qa {
            Text(String(qa.commandCount)).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("qa.tv.command-count")
        }
        #endif
    }
    @ToolbarContentBuilder private var panelToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Back") { model.tvPanel = false }.accessibilityIdentifier("tv.close")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Connect TV") { model.pairingSheet = true }
                Button("Disconnect",role: .destructive) { Task { await model.tv.disconnect() } }
            } label: { Image(systemName: "ellipsis") }
        }
    }
    private var timeline: some View {
        VStack(spacing: 5) {
            Slider(value: $seek,in: 0...max(1,state.duration),onEditingChanged: { editing in
                if editing { dragObservation = state }
                else if let observed = dragObservation { let position = seek; dragObservation = nil; model.control(observed: observed) { lease in _ = try await model.tv.command("seek_to",payload: ["seconds": .number(position)],lease: lease) } }
            }).disabled(state.duration <= 0 || !state.online).accessibilityIdentifier("tv.seek")
                .onChange(of: state.position) { _,value in if dragObservation == nil { seek = min(value,max(1,state.duration)) } }.onAppear { seek = min(state.position,max(1,state.duration)) }
            HStack { Text(clock(seek)); Spacer(); Text(clock(state.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private func key(_ value: Int64) { model.send("key",payload: ["code": .integer(value)]) }
    private func sendChosenEpisode() {
        defer { pendingEpisode = nil }
        guard model.tvPanel, let intent = pendingEpisode else { return }
        // Present takeover only after the episode sheet is fully dismissed.
        model.control(observed: intent.observed) { [weak model] lease in
            guard let model, model.tv.state.watchURL == intent.observed.watchURL else { throw CoreError.message("The TV episode changed. Choose it again.") }
            try await model.tv.load(url: intent.url,lease: lease)
        }
    }
    private func circle(_ icon: String,_ label: String,size: CGFloat,primary: Bool = false,action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: primary ? 26 : 22,weight: .medium)).frame(width: size,height: size).background(primary ? Theme.accent : Theme.surface,in: Circle()).foregroundStyle(primary ? Theme.background : .white) }.accessibilityLabel(label)
    }
    private func clock(_ value: Double) -> String { let value = value.isFinite ? Int(min(Double(Int32.max),max(0,value))) : 0; return String(format: "%d:%02d",value / 60,value % 60) }
}

private struct TVEpisodePresentation: Identifiable {
    let id = UUID()
    let observed: TVState
}

private struct TVEpisodeIntent {
    let observed: TVState
    let url: URL
}

private struct TVEpisodePicker: View {
    let observed: TVState
    let choose: (URL) -> Void
    @State private var episode: String
    @Environment(\.dismiss) private var dismiss
    init(observed: TVState,choose: @escaping (URL) -> Void) {
        self.observed = observed; self.choose = choose
        let value = Double(observed.episode)
        _episode = State(initialValue: value.flatMap { $0.isFinite && $0 >= 0 && $0 < 99999 && $0.rounded(.down) == $0 ? String(Int($0) + 1) : nil } ?? "")
    }
    private var target: URL? {
        let episode = episode.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",",with: ".")
        guard episode.range(of: "^[0-9]{1,5}(\\.[0-9]{1,3})?\\z",options: .regularExpression) != nil,
              let watch = observed.watchURL, AppWebPolicy.isProvider(watch), watch.path.hasPrefix("/watch/"),
              var parts = URLComponents(url: watch,resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "ep",value: episode)]; parts.fragment = nil
        return parts.url
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Episode number",text: $episode).keyboardType(.decimalPad).accessibilityIdentifier("tv.episode.number")
                Text("Confirm the episode number. Specials and fractional episodes are not guessed.").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Play episode on TV").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Play on TV") { if let target { choose(target); dismiss() } }.disabled(target == nil).accessibilityIdentifier("tv.episode.submit") }
                }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}
struct TakeoverAlert: ViewModifier {
    @ObservedObject var model: AppModel
    var enabled: Bool
    func body(content: Content) -> some View {
        content.alert("Take over TV?",isPresented: Binding(get: { enabled && model.takeover != nil },set: { _ in })) {
            Button("Cancel",role: .cancel) { model.takeover = nil }; Button("Take over") { model.confirmTakeover() }
        } message: { Text("\(model.takeover?.observed.control.ownerName ?? "Another device") controls this TV. Taking over will give this device control.") }
    }
}
struct PairingScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var discovery: TVDiscovery
    @State private var address: String
    @State private var pin = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; discovery = model.discovery; _address = State(initialValue: model.tv.state.host) }
    private var valid: Bool { (try? TVAddress.host(address)) != nil && pin.range(of: "^[0-9]{6}\\z",options: .regularExpression) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Open Anime Sync on your TV and choose Phone remote to see its six-digit pairing code.") }
                Section("TV address") {
                    TextField("TV’s local IP address",text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("tv.pair.address")
                    ForEach(discovery.candidates) { device in Button(device.name + " · " + device.host) { address = device.host } }
                    if !discovery.message.isEmpty { Text(discovery.message).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Pairing code") { TextField("Six-digit code",text: $pin).keyboardType(.numberPad).accessibilityIdentifier("tv.pair.pin") }
                if let error { Text(error).foregroundStyle(.red) }
                Button(model.tv.pairing ? "Connecting…" : "Pair TV") {
                    Task { do { try await model.tv.beginPairing(address: address,pin: pin); dismiss() } catch is CancellationError {} catch { self.error = error.localizedDescription } }
                }.disabled(!valid || model.tv.pairing).accessibilityIdentifier("tv.pair.submit")
                Section { Text("On Tailscale, use your saved home address with the home subnet route enabled. Pairing is kept only on this device.").font(.footnote) }
            }.navigationTitle("Connect TV").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.tv.cancelPairing(); dismiss() }.accessibilityIdentifier("tv.pair.cancel") } }
        }.preferredColorScheme(.dark).tint(Theme.accent).onAppear { if !model.fixture { discovery.start() } }.onDisappear { discovery.stop() }
    }
}
