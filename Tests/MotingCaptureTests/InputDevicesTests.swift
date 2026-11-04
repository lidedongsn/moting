import CoreAudio
import Testing
@testable import MotingCapture

private struct Gone: Error {}

@Test func followsSystemDefaultWhenNothingChosen() throws {
    #expect(try MicSource.pick(fixedUID: nil, lookup: { _ in 7 }, fallback: { 3 }) == 3)
}

@Test func usesChosenDeviceWhenConnected() throws {
    #expect(try MicSource.pick(fixedUID: "usb", lookup: { _ in 7 }, fallback: { 3 }) == 7)
}

@Test func fallsBackToSystemDefaultWhenChosenDeviceIsGone() throws {
    #expect(try MicSource.pick(fixedUID: "usb", lookup: { _ in throw Gone() }, fallback: { 3 }) == 3)
}

@Test func ownTapDeviceIsNotOfferedAsMicrophone() {
    #expect(!InputDevices.isSelectable(uid: "moting-tap-123"))
    #expect(!InputDevices.isSelectable(uid: "CADefaultDeviceAggregate-1"))
    #expect(InputDevices.isSelectable(uid: "BuiltInMicrophoneDevice"))
}
