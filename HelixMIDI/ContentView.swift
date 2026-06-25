import CoreMIDI
import SwiftUI
import UniformTypeIdentifiers

private let allMIDIDestinationsID = MIDIUniqueID.min
private let allMIDISourcesID = MIDIUniqueID.max

struct ContentView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var midi: MIDIManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var draggedButton: ControlButton?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var isSettingsPresented = false
    @State private var isExporterPresented = false
    @State private var isImporterPresented = false
    @State private var exportDocument = ControllerSettingsDocument()
    @State private var settingsError: SettingsError?
    @State private var isCurrentSongPendingPlayPause = false
    @State private var isApplyingMIDISync = false
    @State private var isPlaybackRunning = false
    @State private var isMonitorPresented = false
    @State private var flashOn = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
    // Hard on/off blink (not smooth) for the cued-song indicator — easy to read on a dark stage.
    private let flashClock = Timer.publish(every: 0.26, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                libraryPanel
                buttonGrid
                midiFooter
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(appBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    titleView
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        midi.refreshDestinations()
                        midi.refreshSources()
                    } label: {
                        Label("Refresh MIDI", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(for: target)
                    .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $isSettingsPresented) {
                settingsSheet
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isMonitorPresented) {
                MIDIMonitorView(midi: midi)
            }
            .fileExporter(
                isPresented: $isExporterPresented,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Take Controller Settings"
            ) { result in
                if case .failure(let error) = result {
                    settingsError = SettingsError(message: error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.json]
            ) { result in
                importSettings(from: result)
            }
            .alert(item: $settingsError) { error in
                Alert(
                    title: Text("Settings Error"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onChange(of: midi.latestSyncEvent) { _, event in
                guard let event else { return }
                applyMIDISync(event)
            }
            .onChange(of: store.selectedSong) { _, newValue in
                guard !isApplyingMIDISync else { return }
                isCurrentSongPendingPlayPause = true
                isPlaybackRunning = false
                // Cue by playlist POSITION (what the Stadium expects), not the song's identity.
                let cue = store.cuePosition(forSong: newValue) ?? newValue
                midi.sendControlChange(10, value: UInt8(cue))
            }
            .overlay {
                if midi.isScanning {
                    scanOverlay
                }
            }
            .onReceive(flashClock) { _ in
                if isCurrentSongPendingPlayPause {
                    flashOn.toggle()
                }
            }
        }
    }

    private var titleView: some View {
        HStack(spacing: 10) {
            Image("ControllerLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text("TAKE CTRL")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.primary)

                Text("Helix Stadium MIDI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(secondaryText)
            }
        }
    }


    private var libraryPanel: some View {
        HStack(spacing: 18) {
            activeSetlistPanel

            LibrarySelectorView(
                kind: .song,
                value: $store.selectedSong,
                title: store.title(forSong: store.selectedSong),
                order: store.songPickerOrder,
                accent: .takeCyan,
                secondaryText: secondaryText,
                panelStroke: panelStroke,
                displayName: { store.title(forSong: $0) }
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var activeSelectionName: String {
        if let slot = store.activeSetlistSlot { return store.setlistName(slot) }
        return "Song Library"
    }

    private var activeSetlistPanel: some View {
        let isLibrary = store.activeSetlistSlot == nil
        let accent = isLibrary ? Color.takeCyan : Color.takeViolet

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.16))
                    Image(systemName: isLibrary ? "music.note.list" : "list.number")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isLibrary ? "LIBRARY" : "SETLIST")
                        .font(.caption.weight(.black))
                        .foregroundStyle(accent)

                    Text(activeSelectionName)
                        .font(.title2.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if !isLibrary {
                    Button {
                        store.activeSetlistSlot = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Song Library")
                }

                Spacer()

                Text("\(store.songPickerOrder.count) songs")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(secondaryText)
            }

            HStack(spacing: 10) {
                Menu {
                    Button {
                        store.activeSetlistSlot = nil
                    } label: {
                        Label("Library", systemImage: isLibrary ? "checkmark" : "music.note.list")
                    }

                    if !store.setlistSlots.isEmpty {
                        Divider()
                        ForEach(store.setlistSlots, id: \.self) { slot in
                            Button {
                                store.activeSetlistSlot = slot
                            } label: {
                                Label(store.setlistName(slot), systemImage: store.activeSetlistSlot == slot ? "checkmark" : "list.number")
                            }
                        }
                    }

                    Divider()

                    Button {
                        store.createSetlist()
                    } label: {
                        Label("New Setlist", systemImage: "plus")
                    }

                    if let slot = store.activeSetlistSlot {
                        Button {
                            renameText = store.playlistNames[slot] ?? ""
                            renameTarget = .playlist(slot)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            store.clearActiveSetlist()
                        } label: {
                            Label("Clear Songs", systemImage: "xmark.circle")
                        }

                        Button(role: .destructive) {
                            store.deleteActiveSetlist()
                        } label: {
                            Label("Delete Setlist", systemImage: "trash")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 14, weight: .bold))
                        Text("Setlist")
                            .font(.callout.weight(.bold))
                        Spacer()
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    runSongScan()
                } label: {
                    Label("Sync", systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout.weight(.bold))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.takeGreen)
                .disabled(midi.isScanning)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var buttonGrid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(store.buttons) { button in
                ControlButtonView(button: button, palette: palette(for: button), previewText: previewText(for: button)) {
                    trigger(button)
                }
                .overlay {
                    if button.id == "playPause" {
                        playPauseStatusOverlay
                    }
                }
                .draggable(button.id)
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first,
                          let source = store.buttons.first(where: { $0.id == id }) else {
                        return false
                    }

                    store.moveButton(from: source, to: button)
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted {
                        draggedButton = button
                    } else if draggedButton == button {
                        draggedButton = nil
                    }
                }
                .scaleEffect(draggedButton == button ? 0.98 : 1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Over the Play/Pause pad: the current track plus its transport state. Hard-blinks
    /// (gold ⇄ normal) while a song is cued but not yet played; static once playing/paused.
    private var playPauseStatusOverlay: some View {
        let name = store.title(forSong: store.selectedSong)
        let pending = isCurrentSongPendingPlayPause

        let label = pending
            ? name
            : (isPlaybackRunning ? "\(name) — PLAYING" : "\(name) — PAUSED")

        return Text(label)
            .font(.system(size: 19, weight: .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cued: the label blinks hard from 0 → 100 opacity. Playing/paused: solid, no
            // change to the button itself.
            .opacity(pending && !flashOn ? 0 : 1)
            .animation(nil, value: flashOn)
            .allowsHitTesting(false)
    }

    private func trigger(_ button: ControlButton) {
        switch button.id {
        case "cycleClear":
            stopTransport()
            return
        case "previousSong":
            // Walk the active setlist (or numeric ±1 if empty). Changing selectedSong
            // fires CC 10 via onChange — we deliberately do not send the CC 49 step.
            store.selectedSong = adjacentSong(offset: -1)
            return
        case "nextSong":
            store.selectedSong = adjacentSong(offset: 1)
            return
        default:
            break
        }

        midi.sendControlChange(button.controlChange, value: button.midiValue)

        if button.id == "playPause" {
            isCurrentSongPendingPlayPause = false
            isPlaybackRunning.toggle()
        }
    }

    private func adjacentSong(offset: Int) -> Int {
        store.adjacentSong(from: store.selectedSong, offset: offset)
    }

    private func runSongScan() {
        guard !midi.isScanning else { return }
        let limit = store.syncScanLimit
        Task {
            if let scanned = await midi.scanSongs(upTo: limit) {
                store.applyScannedOrder(scanned)
            }
        }
    }

    private var scanOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Discovering Setlist Order")
                    .font(.title2.weight(.black))

                ProgressView(value: Double(midi.scanProgress), total: Double(max(midi.scanTotal, 1)))
                    .tint(.takeGreen)

                Text("\(midi.scanFoundCount) songs in order  ·  position \(midi.scanProgress)")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(secondaryText)

                Button {
                    midi.stopScan()
                } label: {
                    Label("Stop & Keep Found", systemImage: "stop.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.takeRed)
            }
            .padding(28)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(40)
        }
    }


    private func stopTransport() {
        midi.sendStop(shouldTogglePlayPause: isPlaybackRunning)
        isPlaybackRunning = false
        isCurrentSongPendingPlayPause = false
    }

    private func applyMIDISync(_ event: MIDISyncEvent) {
        isApplyingMIDISync = true

        switch event.kind {
        case .playlist:
            break // Playlists are app-side only and pinned to 0 — ignore incoming CC 63.
        case .song:
            store.selectedSong = event.value
            // A live marker means the Stadium is playing across 00:00 — reflect that.
            isCurrentSongPendingPlayPause = false
            isPlaybackRunning = true
        }

        DispatchQueue.main.async {
            isApplyingMIDISync = false
        }
    }

    private func previewText(for button: ControlButton) -> String? {
        switch button.id {
        case "previousSong":
            let value = adjacentSong(offset: -1)
            return "Would select \(value) - \(store.title(forSong: value))"
        case "nextSong":
            let value = adjacentSong(offset: 1)
            return "Would select \(value) - \(store.title(forSong: value))"
        default:
            return nil
        }
    }

    private var midiFooter: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(midi.destinations.isEmpty ? Color.takeRed.opacity(0.16) : Color.takeGreen.opacity(0.18))
                    .frame(width: 38, height: 38)

                Image(systemName: midi.destinations.isEmpty ? "cable.connector.slash" : "cable.connector")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(midi.destinations.isEmpty ? Color.takeRed : Color.takeGreen)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(midi.statusMessage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(secondaryText)

                Text(midi.syncStatusMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryText.opacity(0.86))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var appBackground: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.06, green: 0.07, blue: 0.09), Color(red: 0.10, green: 0.11, blue: 0.14)]
                : [Color(red: 0.96, green: 0.97, blue: 0.99), Color(red: 0.88, green: 0.91, blue: 0.95)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.14, blue: 0.17)
            : Color.white.opacity(0.94)
    }

    private var panelStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    private var secondaryText: Color {
        colorScheme == .dark
            ? Color(red: 0.70, green: 0.73, blue: 0.78)
            : Color(red: 0.37, green: 0.40, blue: 0.46)
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    midiDestinationSettings
                    midiSyncSourceSettings
                    syncSongSettings
                    syncScanSettings

                    NavigationLink {
                        SongEditorView()
                    } label: {
                        settingsRowLabel("Edit Songs", systemImage: "music.note.list", tint: .takeCyan)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SetlistEditorView()
                    } label: {
                        settingsRowLabel("Edit Setlists", systemImage: "list.number", tint: .takeViolet)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isSettingsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            isMonitorPresented = true
                        }
                    } label: {
                        Label("MIDI Monitor", systemImage: "waveform.path")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.takeGreen)

                    Button {
                        exportSettings()
                    } label: {
                        Label("Export Settings", systemImage: "square.and.arrow.up")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.takeCyan)

                    Button {
                        isSettingsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            isImporterPresented = true
                        }
                    } label: {
                        Label("Import Settings", systemImage: "square.and.arrow.down")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.takeRed)
                }
                .padding(24)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isSettingsPresented = false
                    }
                }
            }
        }
    }

    private var syncScanSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Songs to Scan", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline.weight(.black))

            Stepper(value: $store.syncScanLimit, in: 1...127) {
                Text("Scan songs 0–\(store.syncScanLimit)")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Color.takeGreen)
            }

            Text("SYNC probes slots 0 through \(store.syncScanLimit). Keep this just above your highest song number so the scan stays quick.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private func settingsRowLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var midiDestinationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MIDI Destination", systemImage: "cable.connector")
                    .font(.headline.weight(.black))

                Spacer()

                Button {
                    midi.refreshDestinations()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.bordered)
            }

            Picker("MIDI Destination", selection: midiDestinationSelection) {
                Text("All Destinations")
                    .tag(allMIDIDestinationsID)

                ForEach(midi.destinations) { destination in
                    Text(destination.name)
                        .tag(destination.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .tint(.takeCyan)
            .disabled(midi.destinations.isEmpty)

            Text(midi.destinations.isEmpty ? "No MIDI destinations found" : midi.statusMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var midiDestinationSelection: Binding<MIDIUniqueID> {
        Binding {
            midi.selectedDestinationID ?? allMIDIDestinationsID
        } set: { selectedID in
            if selectedID == allMIDIDestinationsID {
                midi.selectAllDestinations()
            } else if let destination = midi.destinations.first(where: { $0.id == selectedID }) {
                midi.selectDestination(destination)
            }
        }
    }

    private var midiSyncSourceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MIDI Sync Source", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline.weight(.black))

                Spacer()

                Button {
                    midi.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.bordered)
            }

            Picker("MIDI Sync Source", selection: midiSourceSelection) {
                Text("All Sources")
                    .tag(allMIDISourcesID)

                ForEach(midi.sources) { source in
                    Text(source.name)
                        .tag(source.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .tint(.takeCyan)
            .disabled(midi.sources.isEmpty)

            Text(midi.sources.isEmpty ? "No MIDI sources found" : midi.syncStatusMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var midiSourceSelection: Binding<MIDIUniqueID> {
        Binding {
            midi.selectedSourceID ?? allMIDISourcesID
        } set: { selectedID in
            if selectedID == allMIDISourcesID {
                midi.selectAllSources()
            } else if let source = midi.sources.first(where: { $0.id == selectedID }) {
                midi.selectSource(source)
            }
        }
    }

    private var syncSongSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sync Song", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline.weight(.black))

            Picker("Sync Song", selection: $store.syncSong) {
                ForEach(0...127, id: \.self) { value in
                    Text("\(value) - \(store.title(forSong: value))")
                        .tag(value)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .tint(.takeGreen)

            HStack(spacing: 8) {
                Text("Song \(store.syncSong)")
                    .font(.caption.monospacedDigit().weight(.black))
                    .foregroundStyle(Color.takeGreen)

                Text(store.title(forSong: store.syncSong))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private func renameSheet(for target: RenameTarget) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(target.title)
                    .font(.title3.weight(.black))

                TextField(target.placeholder, text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit {
                        saveRename(for: target)
                    }

                Text("Value \(target.value)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(secondaryText)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        renameTarget = nil
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveRename(for: target)
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func saveRename(for target: RenameTarget) {
        switch target {
        case .playlist:
            store.renamePlaylist(target.value, renameText)
        case .song:
            store.renameSong(target.value, renameText)
        }

        renameTarget = nil
    }

    private func exportSettings() {
        do {
            exportDocument = ControllerSettingsDocument(data: try store.exportSettingsData())
            isSettingsPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isExporterPresented = true
            }
        } catch {
            settingsError = SettingsError(message: error.localizedDescription)
        }
    }

    private func importSettings(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try store.importSettingsData(Data(contentsOf: url))
        } catch {
            settingsError = SettingsError(message: error.localizedDescription)
        }
    }

    private func palette(for button: ControlButton) -> ButtonPalette {
        switch button.id {
        case "returnToZero":
            return ButtonPalette(base: .takeRed, secondary: .takeGold, icon: "backward.end.fill")
        case "cycleClear":
            return ButtonPalette(base: .takeAmber, secondary: .takeOrange, icon: "xmark.circle.fill")
        case "cycleContinue":
            return ButtonPalette(base: .takeGreen, secondary: .takeMint, icon: "repeat")
        case "previousSong":
            return ButtonPalette(base: .takeBlue, secondary: .takeCyan, icon: "backward.fill")
        case "nextSong":
            return ButtonPalette(base: .takePurple, secondary: .takePink, icon: "forward.fill")
        case "previousMarker":
            return ButtonPalette(base: .takeTeal, secondary: .takeBlue, icon: "arrowtriangle.left.circle.fill")
        case "nextMarker":
            return ButtonPalette(base: .takePink, secondary: .takeRed, icon: "arrowtriangle.right.circle.fill")
        default:
            return ButtonPalette(base: .takeIndigo, secondary: .takeViolet, icon: "playpause.fill")
        }
    }
}

private struct ControllerSettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SettingsError: Identifiable {
    let id = UUID()
    let message: String
}

private enum RenameTarget: Identifiable {
    case playlist(Int)
    case song(Int)

    var id: String {
        switch self {
        case .playlist(let value):
            return "playlist-\(value)"
        case .song(let value):
            return "song-\(value)"
        }
    }

    var value: Int {
        switch self {
        case .playlist(let value), .song(let value):
            return value
        }
    }

    var title: String {
        switch self {
        case .playlist:
            return "Playlist Name"
        case .song:
            return "Song Name"
        }
    }

    var placeholder: String {
        switch self {
        case .playlist(let value):
            return value == 0 ? "SONG LIBRARY" : "Playlist \(value)"
        case .song(let value):
            return "Song \(value)"
        }
    }
}

private enum LibraryKind {
    case playlist
    case song

    var label: String {
        switch self {
        case .playlist:
            return "Playlist"
        case .song:
            return "Song"
        }
    }

    var midiLabel: String {
        switch self {
        case .playlist:
            return "CC63"
        case .song:
            return "CC10"
        }
    }

    var icon: String {
        switch self {
        case .playlist:
            return "music.note.list"
        case .song:
            return "music.note"
        }
    }
}

private struct LibrarySelectorView: View {
    @Binding var value: Int

    let kind: LibraryKind
    let title: String
    let order: [Int]
    let accent: Color
    let secondaryText: Color
    let panelStroke: Color
    let displayName: (Int) -> String

    init(
        kind: LibraryKind,
        value: Binding<Int>,
        title: String,
        order: [Int],
        accent: Color,
        secondaryText: Color,
        panelStroke: Color,
        displayName: @escaping (Int) -> String
    ) {
        self.kind = kind
        self._value = value
        self.title = title
        self.order = order
        self.accent = accent
        self.secondaryText = secondaryText
        self.panelStroke = panelStroke
        self.displayName = displayName
    }

    /// 1-based position of the current song within the discovered order (0 if not in it).
    private var positionInOrder: Int {
        (order.firstIndex(of: value)).map { $0 + 1 } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pickerMenu {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(0.16))

                        Image(systemName: kind.icon)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(kind.label)
                                .font(.headline.weight(.black))

                            Text(kind.midiLabel)
                                .font(.caption.monospacedDigit().weight(.black))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }

                        Text(title)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer()

                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 42, height: 42)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .contentShape(Rectangle())
            }

            HStack(spacing: 12) {
                stepButton(systemName: "minus", amount: -1)

                pickerMenu {
                    Text("\(value)")
                        .font(.system(size: 42, weight: .black).monospacedDigit())
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }

                stepButton(systemName: "plus", amount: 1)
            }

            pickerMenu {
                HStack(spacing: 10) {
                    Label("Choose \(kind.label)", systemImage: "chevron.down")
                        .font(.callout.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(positionInOrder > 0 ? "\(positionInOrder) of \(order.count)" : "CC10 \(value)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 88, alignment: .trailing)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private func stepButton(systemName: String, amount: Int) -> some View {
        Button {
            step(amount)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .black))
                .frame(width: 52, height: 58)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .disabled(stepDisabled(amount))
    }

    /// Steps through the discovered order; falls back to numeric ±1 if there's no order yet.
    private func step(_ amount: Int) {
        guard !order.isEmpty else {
            value = min(max(value + amount, 0), 127)
            return
        }

        if let index = order.firstIndex(of: value) {
            let target = min(max(index + amount, 0), order.count - 1)
            value = order[target]
        } else {
            value = amount >= 0 ? (order.first ?? value) : (order.last ?? value)
        }
    }

    private func stepDisabled(_ amount: Int) -> Bool {
        guard !order.isEmpty, let index = order.firstIndex(of: value) else { return false }
        return (index == 0 && amount < 0) || (index == order.count - 1 && amount > 0)
    }

    private func pickerMenu<LabelContent: View>(@ViewBuilder label: () -> LabelContent) -> some View {
        Menu {
            Picker(kind.label, selection: $value) {
                ForEach(Array(order.enumerated()), id: \.element) { index, item in
                    Text("\(index + 1). \(displayName(item))")
                        .tag(item)
                }
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

private struct ButtonPalette {
    let base: Color
    let secondary: Color
    let icon: String
}

private struct ControlButtonView: View {
    @Environment(\.colorScheme) private var colorScheme

    let button: ControlButton
    let palette: ButtonPalette
    let previewText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: palette.icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Spacer()

                    Text(button.displayMessage)
                        .font(.headline.monospacedDigit().weight(.black))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 8) {
                    Text(button.title)
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.76)

                    Text(previewText ?? detailText)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 158)
            .padding(18)
            .background(buttonFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
//            .overlay(alignment: .topTrailing) {
//                Circle()
//                    .fill(.white.opacity(colorScheme == .dark ? 0.10 : 0.16))
//                    .frame(width: 96, height: 96)
//                    .offset(x: 30, y: -36)
//            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(colorScheme == .dark ? 0.12 : 0.18), lineWidth: 1)
            )
            .shadow(color: palette.base.opacity(colorScheme == .dark ? 0.22 : 0.26), radius: 12, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var detailText: String {
        button.detailMessage
    }

    private var buttonFill: LinearGradient {
        LinearGradient(
            colors: [palette.base, palette.secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SongEditorView: View {
    @EnvironmentObject private var store: ControllerStore

    var body: some View {
        List {
            Section {
                ForEach(store.knownSongs.sorted(), id: \.self) { value in
                    SongEditorRow(value: value)
                }
                .onDelete { offsets in
                    let sorted = store.knownSongs.sorted()
                    for index in offsets where sorted.indices.contains(index) {
                        store.removeSong(sorted[index])
                    }
                }
            } header: {
                Text("\(store.knownSongs.count) Songs")
            } footer: {
                Text("Edit a name, or tap a song's number to move it to a free slot. Swipe to delete.")
            }

            Section {
                Button {
                    addSong()
                } label: {
                    Label("Add Song", systemImage: "plus")
                }
                .disabled(firstFreeSlot == nil)
            }
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var firstFreeSlot: Int? {
        (0...127).first { !store.knownSongs.contains($0) }
    }

    private func addSong() {
        guard let slot = firstFreeSlot else { return }
        store.setSong(slot, name: "New Song")
    }
}

private struct SongEditorRow: View {
    @EnvironmentObject private var store: ControllerStore
    let value: Int

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Number", selection: numberBinding) {
                    ForEach(availableNumbers, id: \.self) { number in
                        Text("\(number)").tag(number)
                    }
                }
            } label: {
                Text("\(value)")
                    .font(.headline.monospacedDigit().weight(.black))
                    .foregroundStyle(Color.takeCyan)
                    .frame(minWidth: 40)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.takeCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            TextField("Song name", text: nameBinding)
                .textInputAutocapitalization(.words)
        }
    }

    private var availableNumbers: [Int] {
        ([value] + (0...127).filter { !store.knownSongs.contains($0) }).sorted()
    }

    private var numberBinding: Binding<Int> {
        Binding {
            value
        } set: { newValue in
            if newValue != value {
                store.remapSong(from: value, to: newValue)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding {
            let override = store.songNames[value] ?? ""
            if !override.isEmpty { return override }
            return SongLibrary.defaultSongNames[value] ?? ""
        } set: { newName in
            store.renameSong(value, newName)
        }
    }
}

private struct SetlistEditorView: View {
    @EnvironmentObject private var store: ControllerStore

    var body: some View {
        List {
            Section {
                Picker("Editing", selection: setlistSelection) {
                    Text("Select a setlist…").tag(Int?.none)
                    ForEach(store.setlistSlots, id: \.self) { slot in
                        Text(store.setlistName(slot)).tag(Int?.some(slot))
                    }
                }

                Button {
                    store.createSetlist()
                } label: {
                    Label("New Setlist", systemImage: "plus")
                }
            } footer: {
                Text("Setlists are built by hand from the Song Library. The Stadium is cued by each song's library position, so any order works.")
            }

            if let slot = store.activeSetlistSlot {
                Section {
                    let order = store.songs(forPlaylist: slot)
                    if order.isEmpty {
                        Text("No songs yet — add from the Library below.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(order, id: \.self) { song in
                            songLabel(song, accent: .takeViolet)
                        }
                        .onMove { source, destination in
                            store.moveSongs(inPlaylist: slot, from: source, to: destination)
                        }
                        .onDelete { offsets in
                            store.removeSongs(at: offsets, fromPlaylist: slot)
                        }
                    }
                } header: {
                    Text("Order — \(store.songs(forPlaylist: slot).count) songs")
                } footer: {
                    Text("Drag to reorder (Edit), swipe to remove.")
                }

                Section {
                    let available = store.availableSongs(forPlaylist: slot)
                    if available.isEmpty {
                        Text("Every library song is already in this setlist.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(available, id: \.self) { song in
                            Button {
                                store.addSong(song, toPlaylist: slot)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.takeGreen)
                                    songLabel(song)
                                    Spacer()
                                }
                            }
                        }
                    }
                } header: {
                    Text("Add from Library")
                }
            } else {
                Section {
                    Text("Pick a setlist above, or create one, to edit its order.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Setlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private var setlistSelection: Binding<Int?> {
        Binding {
            store.activeSetlistSlot
        } set: { newValue in
            store.activeSetlistSlot = newValue
        }
    }

    private func songLabel(_ song: Int, accent: Color = .takeGreen) -> some View {
        HStack(spacing: 10) {
            Text("\(song)")
                .font(.subheadline.monospacedDigit().weight(.black))
                .foregroundStyle(accent)
                .frame(minWidth: 36, alignment: .leading)

            Text(store.title(forSong: song))
                .lineLimit(1)
        }
    }
}

private struct MIDIMonitorView: View {
    @ObservedObject var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let bottomAnchor = "monitor-bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                logScroll
            }
            .background(background.ignoresSafeArea())
            .navigationTitle("MIDI Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: midi.logText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(midi.logLines.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $midi.isMonitoringEnabled) {
                Label(
                    midi.isMonitoringEnabled ? "Monitoring" : "Paused",
                    systemImage: midi.isMonitoringEnabled ? "dot.radiowaves.left.and.right" : "pause.circle"
                )
                .font(.subheadline.weight(.bold))
            }
            .toggleStyle(.button)
            .tint(.takeGreen)

            Spacer()

            Text("\(midi.logLines.count) events")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(secondaryText)

            Button(role: .destructive) {
                midi.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .tint(.takeRed)
            .disabled(midi.logLines.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if midi.logLines.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(midi.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .onChange(of: midi.logLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(secondaryText.opacity(0.7))

            Text(midi.isMonitoringEnabled ? "Waiting for MIDI traffic…" : "Monitoring is paused")
                .font(.callout.weight(.semibold))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private func color(for line: String) -> Color {
        if line.contains("→") {
            return .takeCyan
        } else if line.contains("←") {
            return .takeGreen
        }
        return secondaryText
    }

    private var secondaryText: Color {
        colorScheme == .dark
            ? Color(red: 0.70, green: 0.73, blue: 0.78)
            : Color(red: 0.37, green: 0.40, blue: 0.46)
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.06, blue: 0.08)
            : Color(red: 0.96, green: 0.97, blue: 0.98)
    }
}

private extension Color {
    static let takeRed = Color(red: 0.94, green: 0.05, blue: 0.08)
    static let takeGold = Color(red: 1.00, green: 0.58, blue: 0.10)
    static let takeAmber = Color(red: 0.98, green: 0.48, blue: 0.12)
    static let takeOrange = Color(red: 0.86, green: 0.22, blue: 0.12)
    static let takeGreen = Color(red: 0.09, green: 0.61, blue: 0.33)
    static let takeMint = Color(red: 0.12, green: 0.76, blue: 0.56)
    static let takeBlue = Color(red: 0.05, green: 0.35, blue: 0.88)
    static let takeCyan = Color(red: 0.00, green: 0.65, blue: 0.86)
    static let takePurple = Color(red: 0.50, green: 0.22, blue: 0.84)
    static let takePink = Color(red: 0.91, green: 0.18, blue: 0.45)
    static let takeTeal = Color(red: 0.00, green: 0.53, blue: 0.57)
    static let takeIndigo = Color(red: 0.23, green: 0.29, blue: 0.86)
    static let takeViolet = Color(red: 0.63, green: 0.22, blue: 0.86)
}

#Preview {
    ContentView()
        .environmentObject(ControllerStore())
        .environmentObject(MIDIManager())
}
