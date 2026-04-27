import Foundation
import SwiftUI

struct ControlButton: Identifiable, Codable, Equatable {
    enum ValueMode: Codable, Equatable {
        case fixed(Int)
        case any
    }

    let id: String
    let title: String
    let controlChange: UInt8
    let valueMode: ValueMode

    var midiValue: UInt8 {
        switch valueMode {
        case .fixed(let value):
            return UInt8(clamping: value)
        case .any:
            return 127
        }
    }
}

extension ControlButton {
    static let defaultButtons: [ControlButton] = [
        ControlButton(id: "previousMarker", title: "Previous Marker", controlChange: 50, valueMode: .fixed(0)),
        ControlButton(id: "nextMarker", title: "Next Marker", controlChange: 50, valueMode: .fixed(127)),
        ControlButton(id: "cycleClear", title: "Cycle Clear", controlChange: 48, valueMode: .fixed(0)),
        ControlButton(id: "returnToZero", title: "Return to Zero", controlChange: 47, valueMode: .any),
        ControlButton(id: "previousSong", title: "Previous Song", controlChange: 49, valueMode: .fixed(0)),
        ControlButton(id: "nextSong", title: "Next Song", controlChange: 49, valueMode: .fixed(127)),
        ControlButton(id: "cycleContinue", title: "Cycle Start/End/Continue", controlChange: 48, valueMode: .fixed(127)),
        ControlButton(id: "playPause", title: "Play/Pause", controlChange: 51, valueMode: .any)
    ]
}

@MainActor
final class ControllerStore: ObservableObject {
    @Published var buttons: [ControlButton] {
        didSet { saveButtons() }
    }

    @Published var selectedPlaylist: Int {
        didSet {
            defaults.set(selectedPlaylist, forKey: Keys.selectedPlaylist)
        }
    }

    @Published var selectedSong: Int {
        didSet {
            defaults.set(selectedSong, forKey: Keys.selectedSong)
        }
    }

    @Published var playlistNames: [Int: String] {
        didSet { saveNames(playlistNames, key: Keys.playlistNames) }
    }

    @Published var songNames: [Int: String] {
        didSet { saveNames(songNames, key: Keys.songNames) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.buttons = Self.loadButtons(from: defaults)
        self.selectedPlaylist = (defaults.object(forKey: Keys.selectedPlaylist) as? Int ?? 0).clamped(to: 0...127)
        self.selectedSong = (defaults.object(forKey: Keys.selectedSong) as? Int ?? 0).clamped(to: 0...127)
        self.playlistNames = Self.loadNames(from: defaults, key: Keys.playlistNames)
        self.songNames = Self.loadNames(from: defaults, key: Keys.songNames)
    }

    func title(forPlaylist value: Int) -> String {
        if value == 0 {
            return playlistNames[value].nonEmpty ?? "SONG LIBRARY"
        }

        return playlistNames[value].nonEmpty ?? "Playlist \(value)"
    }

    func title(forSong value: Int) -> String {
        songNames[value].nonEmpty ?? "Song \(value)"
    }

    func renameSelectedPlaylist(_ name: String) {
        renamePlaylist(selectedPlaylist, name)
    }

    func renameSelectedSong(_ name: String) {
        renameSong(selectedSong, name)
    }

    func renamePlaylist(_ value: Int, _ name: String) {
        playlistNames[value.clamped(to: 0...127)] = normalizedName(name)
    }

    func renameSong(_ value: Int, _ name: String) {
        songNames[value.clamped(to: 0...127)] = normalizedName(name)
    }

    func moveButton(from source: ControlButton, to destination: ControlButton) {
        guard source != destination,
              let sourceIndex = buttons.firstIndex(of: source),
              let destinationIndex = buttons.firstIndex(of: destination) else {
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            let moved = buttons.remove(at: sourceIndex)
            buttons.insert(moved, at: destinationIndex)
        }
    }

    func exportSettingsData() throws -> Data {
        let snapshot = ControllerSettingsSnapshot(
            version: 1,
            selectedPlaylist: selectedPlaylist,
            selectedSong: selectedSong,
            playlistNames: Self.encodeNames(playlistNames),
            songNames: Self.encodeNames(songNames),
            buttons: buttons
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    func importSettingsData(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(ControllerSettingsSnapshot.self, from: data)
        let importedButtons = try Self.validatedButtons(snapshot.buttons)

        buttons = importedButtons
        selectedPlaylist = snapshot.selectedPlaylist.clamped(to: 0...127)
        selectedSong = snapshot.selectedSong.clamped(to: 0...127)
        playlistNames = Self.decodeNames(snapshot.playlistNames)
        songNames = Self.decodeNames(snapshot.songNames)
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveButtons() {
        guard let data = try? JSONEncoder().encode(buttons) else { return }
        defaults.set(data, forKey: Keys.buttons)
    }

    private func saveNames(_ names: [Int: String], key: String) {
        defaults.set(Self.encodeNames(names), forKey: key)
    }

    private static func loadButtons(from defaults: UserDefaults) -> [ControlButton] {
        guard let data = defaults.data(forKey: Keys.buttons),
              let decoded = try? JSONDecoder().decode([ControlButton].self, from: data) else {
            return ControlButton.defaultButtons
        }

        guard let validated = try? validatedButtons(decoded) else {
            return ControlButton.defaultButtons
        }

        return validated
    }

    private static func validatedButtons(_ buttons: [ControlButton]) throws -> [ControlButton] {
        let defaultIDs = Set(ControlButton.defaultButtons.map(\.id))
        let importedIDs = Set(buttons.map(\.id))
        guard defaultIDs == importedIDs, buttons.count == ControlButton.defaultButtons.count else {
            throw SettingsImportError.incompatibleButtons
        }

        return buttons
    }

    private static func loadNames(from defaults: UserDefaults, key: String) -> [Int: String] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }

        return decodeNames(stored)
    }

    private static func encodeNames(_ names: [Int: String]) -> [String: String] {
        names.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value
        }
    }

    private static func decodeNames(_ names: [String: String]) -> [Int: String] {
        names.reduce(into: [Int: String]()) { result, item in
            if let value = Int(item.key), (0...127).contains(value) {
                result[value] = item.value
            }
        }
    }

    private enum Keys {
        static let buttons = "buttons"
        static let selectedPlaylist = "selectedPlaylist"
        static let selectedSong = "selectedSong"
        static let playlistNames = "playlistNames"
        static let songNames = "songNames"
    }
}

struct ControllerSettingsSnapshot: Codable {
    let version: Int
    let selectedPlaylist: Int
    let selectedSong: Int
    let playlistNames: [String: String]
    let songNames: [String: String]
    let buttons: [ControlButton]
}

enum SettingsImportError: LocalizedError {
    case incompatibleButtons

    var errorDescription: String? {
        switch self {
        case .incompatibleButtons:
            return "This settings file was made for a different button layout."
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
