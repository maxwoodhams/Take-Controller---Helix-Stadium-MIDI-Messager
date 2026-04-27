import CoreMIDI
import Foundation

@MainActor
final class MIDIManager: ObservableObject {
    @Published private(set) var destinations: [MIDIDestination] = []
    @Published private(set) var statusMessage = "No MIDI destinations found"

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()

    init() {
        setup()
        refreshDestinations()
    }

    func refreshDestinations() {
        let count = MIDIGetNumberOfDestinations()
        destinations = (0..<count).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            return MIDIDestination(endpoint: endpoint, name: Self.name(for: endpoint))
        }

        statusMessage = destinations.isEmpty
            ? "No MIDI destinations found"
            : "Sending to \(destinations.count) MIDI destination\(destinations.count == 1 ? "" : "s")"
    }

    func sendControlChange(_ controlChange: UInt8, value: UInt8, channel: UInt8 = 0) {
        let status = UInt8(0xB0 | (channel & 0x0F))
        send(bytes: [status, controlChange & 0x7F, value & 0x7F])
        statusMessage = "Sent CC\(controlChange) value \(value)"
    }

    private func setup() {
        MIDIClientCreateWithBlock("TAKE CTRL Client" as CFString, &client) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDestinations()
            }
        }

        MIDIOutputPortCreate(client, "TAKE CTRL Output" as CFString, &outputPort)
    }

    private func send(bytes: [UInt8]) {
        refreshDestinations()
        guard !destinations.isEmpty else {
            statusMessage = "Connect a MIDI destination, then try again"
            return
        }

        var packetList = MIDIPacketList()
        bytes.withUnsafeBufferPointer { buffer in
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, buffer.count, buffer.baseAddress!)
            _ = packet
        }

        for destination in destinations {
            MIDISend(outputPort, destination.endpoint, &packetList)
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
}

struct MIDIDestination: Identifiable, Equatable {
    let endpoint: MIDIEndpointRef
    let name: String

    var id: MIDIEndpointRef { endpoint }
}
