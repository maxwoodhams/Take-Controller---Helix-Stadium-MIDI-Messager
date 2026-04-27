import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var midi: MIDIManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var draggedButton: ControlButton?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

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
                        midi.refreshDestinations()
                    } label: {
                        Label("Refresh MIDI", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(for: target)
                    .presentationDetents([.height(260)])
            }
            .onChange(of: store.selectedPlaylist) { _, newValue in
                midi.sendControlChange(63, value: UInt8(newValue))
            }
            .onChange(of: store.selectedSong) { _, newValue in
                midi.sendControlChange(10, value: UInt8(newValue))
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
            LibrarySelectorView(
                kind: .playlist,
                value: $store.selectedPlaylist,
                title: store.title(forPlaylist: store.selectedPlaylist),
                accent: .takeRed,
                secondaryText: secondaryText,
                panelStroke: panelStroke,
                displayName: { store.title(forPlaylist: $0) },
                rename: {
                    renameText = store.playlistNames[store.selectedPlaylist] ?? ""
                    renameTarget = .playlist(store.selectedPlaylist)
                }
            )

            LibrarySelectorView(
                kind: .song,
                value: $store.selectedSong,
                title: store.title(forSong: store.selectedSong),
                accent: .takeCyan,
                secondaryText: secondaryText,
                panelStroke: panelStroke,
                displayName: { store.title(forSong: $0) },
                rename: {
                    renameText = store.songNames[store.selectedSong] ?? ""
                    renameTarget = .song(store.selectedSong)
                }
            )
        }
    }

    private var buttonGrid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(store.buttons) { button in
                ControlButtonView(button: button, palette: palette(for: button)) {
                    midi.sendControlChange(button.controlChange, value: button.midiValue)
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

            Text(midi.statusMessage)
                .font(.callout.weight(.medium))
                .foregroundStyle(secondaryText)

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
    let accent: Color
    let secondaryText: Color
    let panelStroke: Color
    let displayName: (Int) -> String
    let rename: () -> Void

    init(
        kind: LibraryKind,
        value: Binding<Int>,
        title: String,
        accent: Color,
        secondaryText: Color,
        panelStroke: Color,
        displayName: @escaping (Int) -> String,
        rename: @escaping () -> Void
    ) {
        self.kind = kind
        self._value = value
        self.title = title
        self.accent = accent
        self.secondaryText = secondaryText
        self.panelStroke = panelStroke
        self.displayName = displayName
        self.rename = rename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                Menu {
                    Picker(kind.label, selection: $value) {
                        ForEach(0...127, id: \.self) { item in
                            Text("\(item) - \(displayName(item))")
                                .tag(item)
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }

            HStack(spacing: 12) {
                stepButton(systemName: "minus", amount: -1)

                Text("\(value)")
                    .font(.system(size: 42, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                stepButton(systemName: "plus", amount: 1)
            }

            HStack(spacing: 10) {
                Button {
                    rename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .font(.callout.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(accent)

                Text("Value 0-127")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 88, alignment: .trailing)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private func stepButton(systemName: String, amount: Int) -> some View {
        Button {
            value = min(max(value + amount, 0), 127)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .black))
                .frame(width: 52, height: 58)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .disabled((value == 0 && amount < 0) || (value == 127 && amount > 0))
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

                    Text("CC\(button.controlChange)")
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

                    Text(detailText)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
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
        switch button.valueMode {
        case .any:
            return "CC\(button.controlChange) any"
        case .fixed(let value):
            return "CC\(button.controlChange) value \(value)"
        }
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
