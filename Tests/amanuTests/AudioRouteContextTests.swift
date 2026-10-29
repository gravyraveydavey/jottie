import CoreAudio
import Testing
@testable import amanu

struct AudioRouteContextTests {
    @Test func terminalTypesSeparatePhysicalOutputsFromConnectionTypes() {
        #expect(AudioDevices.classify(terminals: [kAudioStreamTerminalTypeHeadphones]) == "headphones")
        #expect(AudioDevices.classify(terminals: [kAudioStreamTerminalTypeSpeaker]) == "speakers")
        #expect(AudioDevices.classify(terminals: [kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeHeadphones]) == "unknown")
        #expect(AudioDevices.classify(terminals: [kAudioStreamTerminalTypeLine]) == "unknown")
        #expect(AudioDevices.classify(terminals: []) == "unknown")
        #expect(AudioDevices.context(of: nil, input: false).kind == "unknown")
    }
}
