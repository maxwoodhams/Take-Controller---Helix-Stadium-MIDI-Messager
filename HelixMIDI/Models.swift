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

    var displayMessage: String {
        id == "cycleClear" ? "STOP" : "CC\(controlChange)"
    }

    var detailMessage: String {
        if id == "cycleClear" {
            return "Stop + zero"
        }

        switch valueMode {
        case .any:
            return "CC\(controlChange) any"
        case .fixed(let value):
            return "CC\(controlChange) value \(value)"
        }
    }
}

extension ControlButton {
    static let defaultButtons: [ControlButton] = [
        ControlButton(id: "previousMarker", title: "Previous Marker", controlChange: 50, valueMode: .fixed(0)),
        ControlButton(id: "nextMarker", title: "Next Marker", controlChange: 50, valueMode: .fixed(127)),
        ControlButton(id: "cycleClear", title: "STOP", controlChange: 48, valueMode: .fixed(0)),
        ControlButton(id: "returnToZero", title: "Return to Zero", controlChange: 47, valueMode: .any),
        ControlButton(id: "previousSong", title: "Previous Song", controlChange: 49, valueMode: .fixed(0)),
        ControlButton(id: "nextSong", title: "Next Song", controlChange: 49, valueMode: .fixed(127)),
        ControlButton(id: "cycleContinue", title: "Cycle Start/End/Continue", controlChange: 48, valueMode: .fixed(127)),
        ControlButton(id: "playPause", title: "Play/Pause", controlChange: 51, valueMode: .any)
    ]
}

enum SongLibrary {
    /// Songs shipped with the app, numbered 1...26 alphabetically. Slot 0 is left as an
    /// empty/home position. Users can rename or remap any of these in Settings.
    static let defaultSongNames: [Int: String] = [
        1: "A Simple Trick",
        2: "Adeline",
        3: "Alhambra",
        4: "Altered Beast",
        5: "Brother Mine",
        6: "Burning Shame",
        7: "Chapter House",
        8: "Code Talker",
        9: "Dead Man's Jacket",
        10: "Delta City (Old Detroit)",
        11: "Follow the Gun",
        12: "I'm Fucking Terrified Of All Of You",
        13: "Killjoy",
        14: "No End to the Wheel",
        15: "Nothing Left for You",
        16: "Ocelot",
        17: "Outliers",
        18: "Ozymandias",
        19: "Rebreather",
        20: "Red Lagoon",
        21: "Tantalus",
        22: "Thinner",
        23: "Trust",
        24: "Unscathed",
        25: "Wasteland",
        26: "Zero"
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

    @Published var syncSong: Int {
        didSet {
            defaults.set(syncSong, forKey: Keys.syncSong)
        }
    }

    /// Highest song slot SYNC probes (scans 0...syncScanLimit). No point scanning all 127
    /// when there are only a couple dozen songs.
    @Published var syncScanLimit: Int {
        didSet {
            defaults.set(syncScanLimit, forKey: Keys.syncScanLimit)
        }
    }

    @Published var playlistNames: [Int: String] {
        didSet { saveNames(playlistNames, key: Keys.playlistNames) }
    }

    @Published var songNames: [Int: String] {
        didSet { saveNames(songNames, key: Keys.songNames) }
    }

    /// Slots known to hold a real song. Seeded from the shipped table, then refined by SYNC.
    @Published var knownSongs: Set<Int> {
        didSet { defaults.set(knownSongs.sorted(), forKey: Keys.knownSongs) }
    }

    /// App-side setlists: playlist slot -> ordered list of song values. Purely organizational
    /// (no MIDI of its own); drives Next/Previous Song order for the selected playlist.
    @Published var playlistSongs: [Int: [Int]] {
        didSet { savePlaylistSongs() }
    }

    /// The Song Library: song identities discovered by SYNC, in discovery order (for display).
    @Published var songLibraryOrder: [Int] {
        didSet { defaults.set(songLibraryOrder, forKey: Keys.songLibrary) }
    }

    /// Parallel to songLibraryOrder: the ABSOLUTE Stadium cue position of each library song.
    /// Kept separate from the index so a skipped (markerless) song never shifts cue positions.
    @Published var songLibraryPositions: [Int] {
        didSet { defaults.set(songLibraryPositions, forKey: Keys.songLibraryPositions) }
    }

    /// Which setlist is active. nil = Library mode (pick any song in library order); otherwise
    /// the playlist slot whose curated order drives the picker.
    @Published var activeSetlistSlot: Int? {
        didSet {
            if let activeSetlistSlot {
                defaults.set(activeSetlistSlot, forKey: Keys.activeSetlist)
            } else {
                defaults.removeObject(forKey: Keys.activeSetlist)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.buttons = Self.loadButtons(from: defaults)
        self.selectedPlaylist = 0 // Pinned: playlists are app-side only and always slot 0.
        self.selectedSong = (defaults.object(forKey: Keys.selectedSong) as? Int ?? 0).clamped(to: 0...127)
        self.syncSong = (defaults.object(forKey: Keys.syncSong) as? Int ?? 0).clamped(to: 0...127)
        self.syncScanLimit = (defaults.object(forKey: Keys.syncScanLimit) as? Int ?? 30).clamped(to: 1...127)
        self.playlistNames = Self.loadNames(from: defaults, key: Keys.playlistNames)

        // First launch: seed the shipped song names and mark them known.
        if defaults.bool(forKey: Keys.didSeedSongs) {
            self.songNames = Self.loadNames(from: defaults, key: Keys.songNames)
            self.knownSongs = Self.loadKnownSongs(from: defaults)
        } else {
            self.songNames = SongLibrary.defaultSongNames
            self.knownSongs = Set(SongLibrary.defaultSongNames.keys)
            defaults.set(true, forKey: Keys.didSeedSongs)
            defaults.set(Self.encodeNames(SongLibrary.defaultSongNames), forKey: Keys.songNames)
            defaults.set(Set(SongLibrary.defaultSongNames.keys).sorted(), forKey: Keys.knownSongs)
        }

        self.playlistSongs = Self.loadPlaylistSongs(from: defaults)
        self.songLibraryOrder = (defaults.array(forKey: Keys.songLibrary) as? [Int])?.filter { (0...127).contains($0) } ?? []
        self.songLibraryPositions = (defaults.array(forKey: Keys.songLibraryPositions) as? [Int]) ?? []
        self.activeSetlistSlot = defaults.object(forKey: Keys.activeSetlist) as? Int
    }

    func title(forPlaylist value: Int) -> String {
        if value == 0 {
            return playlistNames[value].nonEmpty ?? "SONG LIBRARY"
        }

        return playlistNames[value].nonEmpty ?? "Playlist \(value)"
    }

    func title(forSong value: Int) -> String {
        // The shipped CSV is the absolute mapping: a CC 10 value IS its song. A user rename
        // (songNames) overrides it; otherwise the shipped name always wins so a synced value
        // never degrades to "Song N". Only values outside the CSV fall through.
        if let override = songNames[value].nonEmpty {
            return override
        }
        if let shipped = SongLibrary.defaultSongNames[value] {
            return shipped
        }
        return knownSongs.contains(value) ? "Song \(value)" : "Empty"
    }

    var isSelectedSongEmpty: Bool {
        !knownSongs.contains(selectedSong)
    }

    /// Applies a SYNC scan result: it populates the SONG LIBRARY (the Stadium's own order /
    /// cue map), NOT a setlist. Those songs become the known set and the current song jumps
    /// to the top. Setlists are built by hand from the library and are left untouched.
    func applyScannedOrder(_ scanned: [(identity: Int, position: Int)]) {
        songLibraryOrder = scanned.map(\.identity)
        songLibraryPositions = scanned.map(\.position)
        knownSongs = Set(songLibraryOrder)
        activeSetlistSlot = nil // return to Library so the fresh scan is what's shown
        if let first = songLibraryOrder.first {
            selectedSong = first
        }
    }

    /// Songs shown in the right-hand picker / stepped by Next-Prev: the active setlist if one
    /// is built, otherwise the synced Song Library. Only properly-synced tracks appear — if
    /// nothing has been synced yet, the picker is empty until you run SYNC.
    var songPickerOrder: [Int] {
        activeSetlist.isEmpty ? songLibraryOrder : activeSetlist
    }

    /// Moves a song (name + known flag) from one slot to another. No-op if the destination
    /// is occupied by a different known song, to avoid silently clobbering a mapping.
    @discardableResult
    func remapSong(from oldValue: Int, to newValue: Int) -> Bool {
        let from = oldValue.clamped(to: 0...127)
        let to = newValue.clamped(to: 0...127)
        guard from != to else { return true }
        guard !knownSongs.contains(to) else { return false }

        if let name = songNames.removeValue(forKey: from) {
            songNames[to] = name
        }
        if knownSongs.contains(from) {
            knownSongs.remove(from)
            knownSongs.insert(to)
        }
        if selectedSong == from {
            selectedSong = to
        }
        return true
    }

    /// Adds/updates a song slot from the Settings editor.
    func setSong(_ value: Int, name: String) {
        let slot = value.clamped(to: 0...127)
        let trimmed = normalizedName(name)
        if trimmed.isEmpty {
            songNames.removeValue(forKey: slot)
            knownSongs.remove(slot)
        } else {
            songNames[slot] = trimmed
            knownSongs.insert(slot)
        }
    }

    func removeSong(_ value: Int) {
        songNames.removeValue(forKey: value)
        knownSongs.remove(value)
    }

    // MARK: - Setlists (app-side ordering)

    func songs(forPlaylist value: Int) -> [Int] {
        playlistSongs[value] ?? []
    }

    /// Songs of the active setlist, or empty in Library mode.
    var activeSetlist: [Int] {
        guard let slot = activeSetlistSlot else { return [] }
        return songs(forPlaylist: slot)
    }

    /// Slots that are real setlists: they have a name and/or songs.
    var setlistSlots: [Int] {
        let named = playlistNames.compactMap { (key, value) in value.isEmpty ? nil : key }
        let withSongs = playlistSongs.compactMap { (key, value) in value.isEmpty ? nil : key }
        return Set(named).union(withSongs).sorted()
    }

    func setlistName(_ slot: Int) -> String {
        playlistNames[slot].nonEmpty ?? "Setlist \(slot + 1)"
    }

    /// Creates a new (empty, named) setlist in the lowest free slot and makes it active.
    @discardableResult
    func createSetlist() -> Int {
        let used = Set(setlistSlots)
        let slot = (0...127).first { !used.contains($0) } ?? 0
        playlistNames[slot] = "Setlist \(setlistSlots.count + 1)"
        playlistSongs[slot] = []
        activeSetlistSlot = slot
        return slot
    }

    func clearActiveSetlist() {
        guard let slot = activeSetlistSlot else { return }
        playlistSongs[slot] = []
    }

    func deleteActiveSetlist() {
        guard let slot = activeSetlistSlot else { return }
        playlistSongs.removeValue(forKey: slot)
        playlistNames.removeValue(forKey: slot)
        activeSetlistSlot = nil
    }

    /// The Stadium cues by playlist POSITION (0-based) but reports songs by identity. To cue a
    /// song we know by identity, send its index in the SONG LIBRARY (the Stadium's own order
    /// from SYNC) — never the setlist order, which the Stadium knows nothing about.
    func cuePosition(forSong identity: Int) -> Int? {
        guard let index = songLibraryOrder.firstIndex(of: identity) else { return nil }
        // Use the recorded absolute position; fall back to the index only if positions are
        // missing (e.g. an old persisted library from before positions were tracked).
        return songLibraryPositions.indices.contains(index) ? songLibraryPositions[index] : index
    }

    /// Synced Library songs not already in the given setlist, in Library order — candidates
    /// to add. Only properly-synced tracks are offered.
    func availableSongs(forPlaylist value: Int) -> [Int] {
        let inList = Set(playlistSongs[value] ?? [])
        return songLibraryOrder.filter { !inList.contains($0) }
    }

    func addSong(_ song: Int, toPlaylist playlist: Int) {
        var list = playlistSongs[playlist] ?? []
        guard !list.contains(song) else { return }
        list.append(song)
        playlistSongs[playlist] = list
    }

    func removeSongs(at offsets: IndexSet, fromPlaylist playlist: Int) {
        guard var list = playlistSongs[playlist] else { return }
        list.remove(atOffsets: offsets)
        playlistSongs[playlist] = list
    }

    func moveSongs(inPlaylist playlist: Int, from source: IndexSet, to destination: Int) {
        var list = playlistSongs[playlist] ?? []
        list.move(fromOffsets: source, toOffset: destination)
        playlistSongs[playlist] = list
    }

    /// The next/previous song value, walking the picker order (active setlist, else the Song
    /// Library). Falls back to numeric ±1 when there's nothing to walk.
    func adjacentSong(from current: Int, offset: Int) -> Int {
        let order = songPickerOrder
        guard !order.isEmpty else {
            return (current + offset).clamped(to: 0...127)
        }

        if let index = order.firstIndex(of: current) {
            let target = (index + offset).clamped(to: 0...(order.count - 1))
            return order[target]
        }

        // Current song isn't in the setlist — enter at the appropriate end.
        return offset >= 0 ? (order.first ?? current) : (order.last ?? current)
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
            syncSong: syncSong,
            playlistNames: Self.encodeNames(playlistNames),
            songNames: Self.encodeNames(songNames),
            knownSongs: knownSongs.sorted(),
            playlistSongs: Self.encodeSetlists(playlistSongs),
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
        syncSong = (snapshot.syncSong ?? 0).clamped(to: 0...127)
        playlistNames = Self.decodeNames(snapshot.playlistNames)
        let importedSongNames = Self.decodeNames(snapshot.songNames)
        songNames = importedSongNames
        if let imported = snapshot.knownSongs {
            knownSongs = Set(imported.filter { (0...127).contains($0) })
        } else {
            knownSongs = Set(importedSongNames.keys)
        }
        playlistSongs = Self.decodeSetlists(snapshot.playlistSongs ?? [:])
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

    private func savePlaylistSongs() {
        guard let data = try? JSONEncoder().encode(Self.encodeSetlists(playlistSongs)) else { return }
        defaults.set(data, forKey: Keys.playlistSongs)
    }

    private static func loadPlaylistSongs(from defaults: UserDefaults) -> [Int: [Int]] {
        guard let data = defaults.data(forKey: Keys.playlistSongs),
              let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data) else {
            return [:]
        }
        return decodeSetlists(decoded)
    }

    private static func encodeSetlists(_ setlists: [Int: [Int]]) -> [String: [Int]] {
        setlists.reduce(into: [String: [Int]]()) { result, item in
            result[String(item.key)] = item.value
        }
    }

    private static func decodeSetlists(_ setlists: [String: [Int]]) -> [Int: [Int]] {
        setlists.reduce(into: [Int: [Int]]()) { result, item in
            if let key = Int(item.key), (0...127).contains(key) {
                result[key] = item.value.filter { (0...127).contains($0) }
            }
        }
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

        let defaultButtonsByID = Dictionary(uniqueKeysWithValues: ControlButton.defaultButtons.map { ($0.id, $0) })
        return buttons.compactMap { defaultButtonsByID[$0.id] }
    }

    private static func loadKnownSongs(from defaults: UserDefaults) -> Set<Int> {
        guard let stored = defaults.array(forKey: Keys.knownSongs) as? [Int] else {
            return []
        }
        return Set(stored.filter { (0...127).contains($0) })
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
        static let syncSong = "syncSong"
        static let syncScanLimit = "syncScanLimit"
        static let playlistNames = "playlistNames"
        static let songNames = "songNames"
        static let knownSongs = "knownSongs"
        static let didSeedSongs = "didSeedSongs"
        static let playlistSongs = "playlistSongs"
        static let songLibrary = "songLibrary"
        static let songLibraryPositions = "songLibraryPositions"
        static let activeSetlist = "activeSetlist"
    }
}

struct ControllerSettingsSnapshot: Codable {
    let version: Int
    let selectedPlaylist: Int
    let selectedSong: Int
    let syncSong: Int?
    let playlistNames: [String: String]
    let songNames: [String: String]
    let knownSongs: [Int]?
    let playlistSongs: [String: [Int]]?
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
