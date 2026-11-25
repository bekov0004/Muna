import AppKit
import AudioToolbox
import Combine
import CoreAudio
import SwiftUI

/// An output device: its CoreAudio id and name.
struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// The sound of the Mac through CoreAudio: output volume and mute, the outputs to choose from,
/// microphone mute. Read every second while watched (the quick panel is open).
final class SoundModel: ObservableObject {
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var hasVolume = false
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var currentOutput: AudioDeviceID = 0
    @Published private(set) var hasMicrophone = false
    @Published private(set) var microphoneMuted = false

    private var timer: Timer?

    func watch() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func unwatch() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        let output = Self.defaultDevice(input: false)
        let input = Self.defaultDevice(input: true)
        let newOutputs = Self.outputDevices()
        if newOutputs != outputs { outputs = newOutputs }
        if currentOutput != output { currentOutput = output }
        let level = Self.volume(of: output)
        if hasVolume != (level != nil) { hasVolume = level != nil }
        if let level, abs(level - volume) > 0.001 { volume = level }
        let isMuted = Self.mute(of: output, scope: kAudioDevicePropertyScopeOutput) ?? false
        if muted != isMuted { muted = isMuted }
        let micMuted = Self.mute(of: input, scope: kAudioDevicePropertyScopeInput)
        if hasMicrophone != (input != 0) { hasMicrophone = input != 0 }
        if microphoneMuted != (micMuted ?? false) { microphoneMuted = micMuted ?? false }
    }

    // MARK: actions

    func setVolume(_ value: Double) {
        let level = Float32(min(max(value, 0), 1))
        let device = Self.defaultDevice(input: false)
        guard device != 0 else { return }
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var data = level
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &data)
        if status != noErr {
            // No virtual main volume: set each channel.
            for channel: UInt32 in [1, 2] {
                var channelAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                                mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
                var channelData = level
                _ = AudioObjectSetPropertyData(device, &channelAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &channelData)
            }
        }
        volume = Double(level)
        // Moving the slider up from muted unmutes, as on Linux.
        if muted && level > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        if Self.setMute(Self.defaultDevice(input: false), scope: kAudioDevicePropertyScopeOutput, on) {
            muted = on
        }
    }

    func toggleMute() { setMuted(!muted) }

    func setMicrophoneMuted(_ on: Bool) {
        if Self.setMute(Self.defaultDevice(input: true), scope: kAudioDevicePropertyScopeInput, on) {
            microphoneMuted = on
        }
    }

    func toggleMicrophone() { setMicrophoneMuted(!microphoneMuted) }

    func selectOutput(_ device: AudioDeviceID) {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var data = device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &data)
        if status == noErr { refresh() }
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(input: Bool) -> AudioDeviceID {
        var address = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    private static func volume(of device: AudioDeviceID) -> Double? {
        guard device != 0 else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr {
            return Double(level)
        }
        // Fall back to the main element, then to channel 1.
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var scalar = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                    mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &scalar),
               AudioObjectGetPropertyData(device, &scalar, 0, nil, &size, &level) == noErr {
                return Double(level)
            }
        }
        return nil
    }

    private static func mute(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        guard device != 0 else { return nil }
        var address = address(kAudioDevicePropertyMute, scope: scope)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ device: AudioDeviceID, scope: AudioObjectPropertyScope, _ on: Bool) -> Bool {
        guard device != 0 else { return false }
        var address = address(kAudioDevicePropertyMute, scope: scope)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Devices that have output channels, with their names.
    private static func outputDevices() -> [AudioOutput] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            guard outputChannels(of: device) > 0, let name = name(of: device) else { return nil }
            return AudioOutput(id: device, name: name)
        }
    }

    private static func outputChannels(of device: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// The Sound page of the quick panel: volume with mute, the outputs, the microphone.
struct SoundPage: View {
    @EnvironmentObject var sound: SoundModel

    private var volumeSymbol: String {
        if sound.muted || sound.volume == 0 { return "speaker.slash.fill" }
        if sound.volume < 0.34 { return "speaker.wave.1.fill" }
        if sound.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickBlock {
                HStack {
                    Text("Volume").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(sound.muted ? "muted" : "\(Int((sound.volume * 100).rounded()))%")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(MunaColor.secondary)
                }
                HStack(spacing: 8) {
                    IconButton(symbol: volumeSymbol, tint: sound.muted ? MunaColor.warning : MunaColor.text) {
                        sound.toggleMute()
                    }
                    Slider(value: Binding(get: { sound.volume }, set: { sound.setVolume($0) }), in: 0...1)
                        .controlSize(.small)
                        .disabled(!sound.hasVolume)
                }
            }
            QuickBlock {
                Text("Output").font(.system(size: 12, weight: .semibold))
                if sound.outputs.isEmpty {
                    Text("No output device").font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
                ForEach(sound.outputs) { output in
                    Button(action: { sound.selectOutput(output.id) }) {
                        HStack(spacing: 8) {
                            Image(systemName: output.id == sound.currentOutput ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundColor(output.id == sound.currentOutput ? MunaColor.accent : MunaColor.secondary)
                            Text(output.name)
                                .font(.system(size: 12))
                                .foregroundColor(MunaColor.text)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if sound.hasMicrophone {
                QuickBlock {
                    HStack {
                        Image(systemName: sound.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 12))
                            .foregroundColor(sound.microphoneMuted ? MunaColor.warning : MunaColor.text)
                        Text("Microphone").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Pill(label: sound.microphoneMuted ? "Muted" : "On", active: !sound.microphoneMuted) {
                            sound.toggleMicrophone()
                        }
                    }
                }
            }
        }
        .foregroundColor(MunaColor.text)
    }
}
