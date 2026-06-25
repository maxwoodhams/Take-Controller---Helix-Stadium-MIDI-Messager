import CoreMIDI
import Foundation

@MainActor
final class MIDIManager: ObservableObject {
    @Published private(set) var destinations: [MIDIDestination] = []
    @Published private(set) var sources: [MIDIInputSource] = []
    @Published private(set) var statusMessage = "No MIDI destinations found"
    @Published private(set) var syncStatusMessage = "No MIDI sources found"
    @Published private(set) var latestSyncEvent: MIDISyncEvent?
    @Published var selectedDestinationID: MIDIDestination.ID? {
        didSet {
            if let selectedDestinationID {
                defaults.set(selectedDestinationID, forKey: Keys.selectedDestinationID)
            } else {
                defaults.removeObject(forKey: Keys.selectedDestinationID)
            }
            updateStatusMessage()
        }
    }
    @Published var selectedSourceID: MIDIInputSource.ID? {
        didSet {
            if let selectedSourceID {
                defaults.set(selectedSourceID, forKey: Keys.selectedSourceID)
            } else {
                defaults.removeObject(forKey: Keys.selectedSourceID)
            }
            reconnectSources()
            updateSyncStatusMessage()
        }
    }

    @Published var isMonitoringEnabled: Bool = true
    @Published private(set) var logLines: [String] = []

    func clearLog() {
        logLines.removeAll()
    }

    var logText: String { logLines.joined(separator: "\n") }

    private func appendLog(_ line: String) {
        guard isMonitoringEnabled else { return }
        let ts = Self.timestampString()
        let entry = "[\(ts)] \(line)"
        logLines.append(entry)
        // Trim to last 500 entries to avoid unbounded growth
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    // MARK: - Song scan
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = 0      // slots probed so far
    @Published private(set) var scanTotal = 128       // slots to probe this run
    @Published private(set) var scanFoundCount = 0    // populated slots discovered

    private var scanWaiter: CheckedContinuation<Int?, Never>?   // resolves with the echoed song value
    private var scanGeneration = 0                    // invalidates stale per-position timeouts
    private var scanStopped = false

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: [MIDIInputSource.ID: MIDIEndpointRef] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedDestinationID = defaults.object(forKey: Keys.selectedDestinationID) as? MIDIUniqueID
        self.selectedSourceID = defaults.object(forKey: Keys.selectedSourceID) as? MIDIUniqueID
        setup()
        refreshDestinations()
        refreshSources()
    }

    func refreshDestinations() {
        let count = MIDIGetNumberOfDestinations()
        destinations = (0..<count).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            return MIDIDestination(
                endpoint: endpoint,
                uniqueID: Self.uniqueID(for: endpoint),
                name: Self.name(for: endpoint)
            )
        }

        if let selectedDestinationID,
           !destinations.contains(where: { $0.id == selectedDestinationID }) {
            self.selectedDestinationID = nil
        }

        updateStatusMessage()
    }

    func refreshSources() {
        let count = MIDIGetNumberOfSources()
        sources = (0..<count).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            return MIDIInputSource(
                endpoint: endpoint,
                uniqueID: Self.uniqueID(for: endpoint),
                name: Self.name(for: endpoint, fallback: "MIDI Source")
            )
        }

        if let selectedSourceID,
           !sources.contains(where: { $0.id == selectedSourceID }) {
            self.selectedSourceID = nil
        } else {
            reconnectSources()
            updateSyncStatusMessage()
        }
    }

    var selectedDestination: MIDIDestination? {
        destinations.first { $0.id == selectedDestinationID }
    }

    var selectedSource: MIDIInputSource? {
        sources.first { $0.id == selectedSourceID }
    }

    func selectDestination(_ destination: MIDIDestination) {
        selectedDestinationID = destination.id
    }

    func selectAllDestinations() {
        selectedDestinationID = nil
    }

    func selectSource(_ source: MIDIInputSource) {
        selectedSourceID = source.id
    }

    func selectAllSources() {
        selectedSourceID = nil
    }

    func sendControlChange(_ controlChange: UInt8, value: UInt8, channel: UInt8 = 0) {
        let status = UInt8(0xB0 | (channel & 0x0F))
        let sentDestinations = send(bytes: [status, controlChange & 0x7F, value & 0x7F])
        guard !sentDestinations.isEmpty else {
            return
        }

        if sentDestinations.count == 1, let destination = sentDestinations.first {
            statusMessage = "Sent CC\(controlChange) value \(value) to \(destination.name)"
        } else {
            statusMessage = "Sent CC\(controlChange) value \(value) to \(sentDestinations.count) destinations"
        }
    }

    func sendStop() {
        sendStop(shouldTogglePlayPause: true)
    }

    func sendStop(shouldTogglePlayPause: Bool) {
        var messages: [[UInt8]] = [
            [0xFC],
            [0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7],
            [0xB0, 47, 0]
        ]

        if shouldTogglePlayPause {
            messages.insert([0xB0, 51, 0], at: 2)
        }

        let sentDestinations = send(messages: messages)
        guard !sentDestinations.isEmpty else {
            return
        }

        if sentDestinations.count == 1, let destination = sentDestinations.first {
            statusMessage = "Sent Stop to \(destination.name)"
        } else {
            statusMessage = "Sent Stop to \(sentDestinations.count) destinations"
        }
    }

    /// Discovers the Helix's setlist ORDER. Cues the first song (CC 63 = 0), then walks the
    /// setlist position by position: play (CC 51) so the Stadium crosses 00:00 and echoes
    /// CC 10 = the song at this position, record it, pause, advance (CC 49 = next song).
    /// Stops when a value repeats (wrapped to the top), a position is silent (end), or the
    /// cap is hit. Returns the ordered list of song values, or nil if it couldn't run / found
    /// nothing.
    @discardableResult
    func scanSongs(perSlotTimeout: Duration = .milliseconds(1300), upTo limit: Int = 127) async -> [(identity: Int, position: Int)]? {
        guard !isScanning else { return nil }

        refreshDestinations()
        guard !destinations.isEmpty else {
            statusMessage = "Connect a MIDI destination, then try again"
            return nil
        }

        refreshSources()
        guard !sources.isEmpty else {
            syncStatusMessage = "Connect a MIDI sync source, then try again"
            return nil
        }

        let cap = max(1, min(limit, 127))
        isScanning = true
        scanStopped = false
        scanProgress = 0
        scanTotal = cap
        scanFoundCount = 0

        // Cue the first song of the setlist, then let it settle.
        _ = send(bytes: [0xB0, 63, 0])
        try? await Task.sleep(for: .milliseconds(160))

        // Each entry is (identity, absolute Helix position). Position = the step index, so a
        // markerless song that gets skipped never shifts the cue positions of later songs.
        var found: [(identity: Int, position: Int)] = []
        var seen: Set<Int> = []
        var consecutiveSilent = 0
        let maxConsecutiveSilent = 4   // tolerate a few markerless songs before calling it the end

        for step in 0..<cap {
            if scanStopped { break }

            var value = await playAndAwaitSongValue(timeout: perSlotTimeout)
            // A just-loaded / slow song can miss the first window — give it one retry before
            // we treat the position as silent.
            if value == nil && !scanStopped {
                value = await playAndAwaitSongValue(timeout: perSlotTimeout)
            }
            if scanStopped { break }

            if let value {
                let name = SongLibrary.defaultSongNames[value] ?? "?"
                if seen.contains(value) {
                    appendLog("⟳ Slot \(step): heard Song \(value) (\(name)) again — wrapped, done")
                    break
                }
                appendLog("⟳ Slot \(step): heard Song \(value) (\(name))")
                seen.insert(value)
                found.append((identity: value, position: step))
                scanFoundCount = found.count
                consecutiveSilent = 0
            } else {
                // Silent position: a song with no 00:00 marker (or past the end). Skip it (its
                // slot is still accounted for via `step`), but give up after several in a row.
                appendLog("⟳ Slot \(step): silent (no marker)")
                consecutiveSilent += 1
                if consecutiveSilent >= maxConsecutiveSilent { break }
            }

            scanProgress = step + 1

            // Advance to the next setlist position and let it settle.
            _ = send(bytes: [0xB0, 49, 127])
            try? await Task.sleep(for: .milliseconds(90))
        }

        // The last probe already paused; only return to zero (a second CC 51 would un-pause).
        _ = send(bytes: [0xB0, 47, 0])

        let stopped = scanStopped
        isScanning = false
        syncStatusMessage = stopped
            ? "Scan stopped — \(found.count) songs"
            : "Scan complete — \(found.count) songs in order"

        guard !found.isEmpty else { return nil }
        return found
    }

    /// Stops the scan early, keeping whatever order was found so far.
    func stopScan() {
        guard isScanning else { return }
        scanStopped = true
        if let waiter = scanWaiter {
            scanWaiter = nil
            scanGeneration &+= 1
            waiter.resume(returning: nil)
        }
    }

    /// Stops scan playback the way the Stadium actually listens: CC 51 pauses, CC 47 returns
    /// to zero. The Stadium ignores 0xFC / MMC, so those are deliberately not used here.
    private func scanStopPlayback() {
        _ = send(bytes: [0xB0, 51, 0])
        _ = send(bytes: [0xB0, 47, 0])
    }

    /// Plays the currently-cued song so the Stadium crosses 00:00 and echoes CC 10, returns
    /// that value (or nil on timeout), then pauses. One play + one pause keeps the CC 51
    /// toggle balanced per position.
    private func playAndAwaitSongValue(timeout: Duration) async -> Int? {
        _ = send(bytes: [0xB0, 51, 127])   // play

        scanGeneration &+= 1
        let generation = scanGeneration

        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            scanWaiter = continuation
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if scanGeneration == generation, let waiter = scanWaiter {
                    scanWaiter = nil
                    waiter.resume(returning: nil)
                }
            }
        }

        _ = send(bytes: [0xB0, 51, 0])     // pause
        return value
    }

    private func setup() {
        MIDIClientCreateWithBlock("TAKE CTRL Client" as CFString, &client) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDestinations()
                self?.refreshSources()
            }
        }

        MIDIOutputPortCreate(client, "TAKE CTRL Output" as CFString, &outputPort)
        MIDIInputPortCreateWithBlock(client, "TAKE CTRL Input" as CFString, &inputPort) { [weak self] packetList, _ in
            // Copy everything out synchronously — packetList is only valid for the duration
            // of this callback. Parse from the copied bytes, never the (soon-dangling) pointer.
            let packets = Self.bytesPerPacket(in: packetList)
            Task { @MainActor in
                guard let self else { return }
                var payloads: [MIDISyncPayload] = []
                for bytes in packets {
                    self.appendLog("← \(Self.describeMessage(bytes, incoming: true))  ·  \(Self.hexString(for: bytes))")
                    payloads.append(contentsOf: Self.syncPayloads(in: bytes))
                }
                if !payloads.isEmpty {
                    self.handleIncomingSync(payloads)
                }
            }
        }
    }

    @discardableResult
    private func send(bytes: [UInt8]) -> [MIDIDestination] {
        send(messages: [bytes])
    }

    @discardableResult
    private func send(messages: [[UInt8]]) -> [MIDIDestination] {
        refreshDestinations()
        guard !destinations.isEmpty else {
            statusMessage = "Connect a MIDI destination, then try again"
            return []
        }

        let sendTargets = selectedDestination.map { [$0] } ?? destinations
        for bytes in messages {
            var packetList = MIDIPacketList()
            let hex = Self.hexString(for: bytes)
            let destinationNames = sendTargets.map { $0.name }.joined(separator: ", ")
            _ = destinationNames
            appendLog("→ \(Self.describeMessage(bytes, incoming: false))  ·  \(hex)")
            bytes.withUnsafeBufferPointer { buffer in
                var packet = MIDIPacketListInit(&packetList)
                packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, buffer.count, buffer.baseAddress!)
                _ = packet
            }

            for destination in sendTargets {
                MIDISend(outputPort, destination.endpoint, &packetList)
            }
        }

        return sendTargets
    }

    private func reconnectSources() {
        guard inputPort != 0 else { return }

        for endpoint in connectedSources.values {
            MIDIPortDisconnectSource(inputPort, endpoint)
        }
        connectedSources.removeAll()

        let syncSources = selectedSource.map { [$0] } ?? sources
        for source in syncSources {
            guard MIDIPortConnectSource(inputPort, source.endpoint, nil) == noErr else {
                continue
            }
            connectedSources[source.id] = source.endpoint
        }
    }

    private func handleIncomingSync(_ payloads: [MIDISyncPayload]) {
        // During a scan, a song marker reports which song sits at the current position.
        // Resolve the waiter with that value; the scan loop pauses and advances.
        if isScanning {
            guard let songValue = payloads.first(where: { $0.kind == .song })?.value,
                  let waiter = scanWaiter else {
                return
            }
            scanWaiter = nil
            scanGeneration &+= 1
            waiter.resume(returning: songValue)
            return
        }

        for payload in payloads {
            latestSyncEvent = MIDISyncEvent(kind: payload.kind, value: payload.value)
        }

        guard let lastPayload = payloads.last else { return }
        let sourceDescription = selectedSource?.name ?? (selectedSourceID == nil ? "MIDI input" : "selected source")
        syncStatusMessage = "Heard \(lastPayload.kind.label.lowercased()) \(lastPayload.value) from \(sourceDescription)"
    }

    private func updateStatusMessage() {
        guard !destinations.isEmpty else {
            statusMessage = "No MIDI destinations found"
            return
        }

        guard selectedDestinationID != nil else {
            statusMessage = "Sending to all MIDI destinations"
            return
        }

        if let selectedDestination {
            statusMessage = "Sending to \(selectedDestination.name)"
        } else {
            statusMessage = "Selected MIDI destination unavailable"
        }
    }

    private func updateSyncStatusMessage() {
        guard !sources.isEmpty else {
            syncStatusMessage = "No MIDI sources found"
            return
        }

        guard selectedSourceID != nil else {
            syncStatusMessage = "Listening to all MIDI sources"
            return
        }

        if let selectedSource {
            syncStatusMessage = "Listening to \(selectedSource.name)"
        } else {
            syncStatusMessage = "Selected MIDI source unavailable"
        }
    }

    private static func name(for endpoint: MIDIEndpointRef, fallback: String = "MIDI Destination") -> String {
        var unmanagedName: Unmanaged<CFString>?
        let result = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)

        guard result == noErr, let name = unmanagedName?.takeRetainedValue() else {
            return fallback
        }

        return name as String
    }

    private static func uniqueID(for endpoint: MIDIEndpointRef) -> MIDIUniqueID {
        var uniqueID = MIDIUniqueID()
        let result = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

        guard result == noErr, uniqueID != 0 else {
            return MIDIUniqueID(endpoint)
        }

        return uniqueID
    }

    private nonisolated static func syncPayloads(in packetList: UnsafePointer<MIDIPacketList>) -> [MIDISyncPayload] {
        var payloads: [MIDISyncPayload] = []
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
                Array(rawBuffer.prefix(Int(packet.length)))
            }

            payloads.append(contentsOf: syncPayloads(in: bytes))
            packet = MIDIPacketNext(&packet).pointee
        }

        return payloads
    }

    private nonisolated static func syncPayloads(in bytes: [UInt8]) -> [MIDISyncPayload] {
        var payloads: [MIDISyncPayload] = []
        var runningStatus: UInt8?
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte >= 0xF8 {
                index += 1
                continue
            }

            if byte >= 0x80 {
                if byte >= 0xF0 {
                    runningStatus = nil
                    index += systemMessageLength(in: bytes, from: index)
                    continue
                }

                runningStatus = byte
                index += 1
            }

            guard let status = runningStatus else {
                index += 1
                continue
            }

            let dataCount = dataByteCount(for: status)
            guard index + dataCount <= bytes.count else { break }

            if status & 0xF0 == 0xB0, dataCount == 2 {
                let controlChange = bytes[index] & 0x7F
                let value = Int(bytes[index + 1] & 0x7F)

                if let kind = MIDISyncKind(controlChange: controlChange) {
                    payloads.append(MIDISyncPayload(kind: kind, value: value))
                }
            }

            index += dataCount
        }

        return payloads
    }

    private nonisolated static func dataByteCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0:
            return 1
        default:
            return 2
        }
    }

    private nonisolated static func systemMessageLength(in bytes: [UInt8], from index: Int) -> Int {
        switch bytes[index] {
        case 0xF0:
            guard let endIndex = bytes[index...].firstIndex(of: 0xF7) else {
                return bytes.count - index
            }
            return endIndex - index + 1
        case 0xF1, 0xF3:
            return 2
        case 0xF2:
            return 3
        default:
            return 1
        }
    }

    // MARK: - Monitoring helpers
    private nonisolated static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private nonisolated static func timestampString() -> String {
        timestampFormatter.string(from: Date())
    }

    private nonisolated static func hexString(for bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Human-readable description of a MIDI message for the monitor (decodes the Stadium's CCs
    /// and resolves CC 10 to its CSV song name).
    private nonisolated static func describeMessage(_ bytes: [UInt8], incoming: Bool) -> String {
        guard let status = bytes.first else { return "empty" }

        if status & 0xF0 == 0xB0, bytes.count >= 3 {
            let cc = bytes[1] & 0x7F
            let value = Int(bytes[2] & 0x7F)
            switch cc {
            case 10:
                // Incoming CC 10 = the song's identity; outgoing CC 10 = a cue by position.
                if incoming {
                    let name = SongLibrary.defaultSongNames[value] ?? "?"
                    return "Song \(value) (\(name))"
                }
                return "Cue position \(value)"
            case 46: return "Marker cue \(value)"
            case 47: return "Return to Zero"
            case 49: return value >= 64 ? "Next Song" : "Prev Song"
            case 50: return value >= 64 ? "Next Marker" : "Prev Marker"
            case 51: return value >= 64 ? "Play" : "Pause"
            case 63: return "Cue Playlist \(value)"
            default: return "CC\(cc)=\(value)"
            }
        }

        switch status {
        case 0xFC: return "MIDI Stop"
        case 0xFA: return "MIDI Start"
        case 0xFB: return "MIDI Continue"
        case 0xF0: return "SysEx"
        default: return "raw"
        }
    }

    private nonisolated static func bytesPerPacket(in packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
        var results: [[UInt8]] = []
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
                Array(rawBuffer.prefix(Int(packet.length)))
            }
            results.append(bytes)
            packet = MIDIPacketNext(&packet).pointee
        }
        return results
    }

    private enum Keys {
        static let selectedDestinationID = "selectedMIDIDestinationID"
        static let selectedSourceID = "selectedMIDISourceID"
    }
}

struct MIDIDestination: Identifiable, Equatable {
    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String

    var id: MIDIUniqueID { uniqueID }
}

struct MIDIInputSource: Identifiable, Equatable {
    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String

    var id: MIDIUniqueID { uniqueID }
}

enum MIDISyncKind: Equatable {
    case playlist
    case song

    init?(controlChange: UInt8) {
        switch controlChange {
        case 63:
            self = .playlist
        case 10:
            self = .song
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .playlist:
            return "Playlist"
        case .song:
            return "Song"
        }
    }
}

struct MIDISyncEvent: Identifiable, Equatable {
    let id = UUID()
    let kind: MIDISyncKind
    let value: Int
}

private struct MIDISyncPayload {
    let kind: MIDISyncKind
    let value: Int
}
