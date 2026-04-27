import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var midi: MIDIManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var draggedButton: ControlButton?
    @State private var playlistName = ""
    @State private var songName = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                pickerPanel
                buttonGrid
                midiFooter
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("TAKE CONTROLLER")
            .toolbar {
                Button {
                    midi.refreshDestinations()
                } label: {
                    Label("Refresh MIDI", systemImage: "arrow.clockwise")
                }
            }
            .onAppear {
                syncNameFields()
            }
            .onChange(of: store.selectedPlaylist) { _, newValue in
                playlistName = store.playlistNames[newValue] ?? ""
                midi.sendControlChange(63, value: UInt8(newValue))
            }
            .onChange(of: store.selectedSong) { _, newValue in
                songName = store.songNames[newValue] ?? ""
                midi.sendControlChange(10, value: UInt8(newValue))
            }
        }
    }

    private var pickerPanel: some View {
        HStack(spacing: 18) {
            selectorGroup(
                title: "Playlist",
                valueText: "\(store.selectedPlaylist)",
                subtitle: store.title(forPlaylist: store.selectedPlaylist),
                accent: .takeRed
            ) {
                valuePicker(
                    title: "Playlist",
                    selection: $store.selectedPlaylist,
                    label: { store.title(forPlaylist: $0) }
                )

                nameField(
                    title: "Playlist Name",
                    text: $playlistName,
                    placeholder: store.selectedPlaylist == 0 ? "SONG LIBRARY" : "Playlist \(store.selectedPlaylist)",
                    onSubmit: { store.renameSelectedPlaylist(playlistName) }
                )
            }

            selectorGroup(
                title: "Song",
                valueText: "\(store.selectedSong)",
                subtitle: store.title(forSong: store.selectedSong),
                accent: .takeCyan
            ) {
                valuePicker(
                    title: "Song",
                    selection: $store.selectedSong,
                    label: { store.title(forSong: $0) }
                )

                nameField(
                    title: "Song Name",
                    text: $songName,
                    placeholder: "Song \(store.selectedSong)",
                    onSubmit: { store.renameSelectedSong(songName) }
                )
            }
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

    private func selectorGroup<Content: View>(
        title: String,
        valueText: String,
        subtitle: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(valueText)
                    .font(.title2.monospacedDigit().weight(.black))
                    .foregroundStyle(accent)
                    .frame(width: 58, height: 48)
                    .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }

                Spacer()
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.10), radius: 14, y: 8)
    }

    private func valuePicker(
        title: String,
        selection: Binding<Int>,
        label: @escaping (Int) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(secondaryText)

            Picker(title, selection: selection) {
                ForEach(0...127, id: \.self) { value in
                    Text("\(value) - \(label(value))")
                        .tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.large)
            .tint(.primary)
        }
    }

    private func nameField(
        title: String,
        text: Binding<String>,
        placeholder: String,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(secondaryText)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(onSubmit)
                .onChange(of: text.wrappedValue) { _, _ in
                    onSubmit()
                }
        }
    }

    private func syncNameFields() {
        playlistName = store.playlistNames[store.selectedPlaylist] ?? ""
        songName = store.songNames[store.selectedSong] ?? ""
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
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.white.opacity(colorScheme == .dark ? 0.10 : 0.16))
                    .frame(width: 96, height: 96)
                    .offset(x: 30, y: -36)
            }
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
