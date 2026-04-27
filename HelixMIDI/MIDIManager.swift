import CoreMIDI
import Foundation

@MainActor
final class MIDIManager: ObservableObject {
    @Published private(set) var destinations: [MIDIDestination] = []
    @Published private(set) var statusMessage = "No MIDI destinations found"
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

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedDestinationID = defaults.object(forKey: Keys.selectedDestinationID) as? MIDIUniqueID
        setup()
        refreshDestinations()
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

    var selectedDestination: MIDIDestination? {
        destinations.first { $0.id == selectedDestinationID }
    }

    func selectDestination(_ destination: MIDIDestination) {
        selectedDestinationID = destination.id
    }

    func selectAllDestinations() {
        selectedDestinationID = nil
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

    private func setup() {
        MIDIClientCreateWithBlock("TAKE CTRL Client" as CFString, &client) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDestinations()
            }
        }

        MIDIOutputPortCreate(client, "TAKE CTRL Output" as CFString, &outputPort)
    }

    @discardableResult
    private func send(bytes: [UInt8]) -> [MIDIDestination] {
        refreshDestinations()
        guard !destinations.isEmpty else {
            statusMessage = "Connect a MIDI destination, then try again"
            return []
        }

        var packetList = MIDIPacketList()
        bytes.withUnsafeBufferPointer { buffer in
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, buffer.count, buffer.baseAddress!)
            _ = packet
        }

        let sendTargets = selectedDestination.map { [$0] } ?? destinations
        for destination in sendTargets {
            MIDISend(outputPort, destination.endpoint, &packetList)
        }

        return sendTargets
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

    private static func name(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        let result = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)

        guard result == noErr, let name = unmanagedName?.takeRetainedValue() else {
            return "MIDI Destination"
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

    private enum Keys {
        static let selectedDestinationID = "selectedMIDIDestinationID"
    }
}

struct MIDIDestination: Identifiable, Equatable {
    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String

    var id: MIDIUniqueID { uniqueID }
}
