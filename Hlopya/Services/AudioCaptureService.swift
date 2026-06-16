import Foundation
import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures system audio via Core Audio Taps and microphone via AVAudioEngine.
/// Uses "System Audio Recording Only" permission (not Screen Recording).
@MainActor
@Observable
final class AudioCaptureService {
    private(set) var isRecording = false
    private(set) var elapsedTime: TimeInterval = 0
    var lastError: String?

    private var systemTap: SystemAudioTap?
    private var micRecorder: MicRecorder?
    private var timer: Timer?
    private(set) var startTime: Date?

    let sampleRate = 16000

    func startRecording(sessionDir: URL) async throws {
        lastError = nil

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw AudioCaptureError.micPermissionDenied }
        default:
            throw AudioCaptureError.micPermissionDenied
        }

        let sysPath = sessionDir.appendingPathComponent("system.wav").path
        let micPath = sessionDir.appendingPathComponent("mic.wav").path

        // System audio via Core Audio Taps (triggers "System Audio Recording Only" permission)
        NSLog("[Hlopya] Starting system audio capture via Core Audio Taps...")
        let sysWriter = try WAVWriter(path: sysPath, sampleRate: sampleRate)
        systemTap = SystemAudioTap(writer: sysWriter, targetRate: sampleRate)
        try systemTap!.start()

        // Microphone via AVAudioEngine
        NSLog("[Hlopya] Starting microphone capture...")
        let micWriter = try WAVWriter(path: micPath, sampleRate: sampleRate)
        micRecorder = MicRecorder(writer: micWriter, targetRate: sampleRate)
        try micRecorder!.start()

        startTime = Date()
        isRecording = true
        elapsedTime = 0

        // Update elapsed time every second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }

        NSLog("[Hlopya] Recording started")
    }

    func stopRecording() async {
        timer?.invalidate()
        timer = nil

        let sysSamplesWritten = systemTap?.totalSamplesWritten ?? 0
        systemTap?.stop()
        systemTap?.writer.close()
        systemTap = nil

        micRecorder?.stop()
        micRecorder = nil

        isRecording = false
        startTime = nil

        if sysSamplesWritten == 0 && elapsedTime > 2 {
            lastError = "System audio captured 0 samples - speaker separation will not work for this recording"
            NSLog("[Hlopya] WARNING: System audio capture produced no samples!")
        }

        NSLog("[Hlopya] Recording stopped (system samples: %d)", sysSamplesWritten)
    }

    var formattedTime: String {
        let total = Int(elapsedTime)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - System Audio Capture via Core Audio Taps (macOS 14.2+)

/// Captures all system audio output using CATapDescription + AudioHardwareCreateProcessTap.
/// This triggers the "System Audio Recording Only" permission (not "Screen Recording").
final class SystemAudioTap {
    let writer: WAVWriter
    let targetRate: Int

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hlopya.system-audio", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var pendingSamples: [Float] = []
    private let minConvertFrames = 4096
    private var callbackCount = 0
    private var totalSamplesReceived = 0
    private(set) var totalSamplesWritten = 0
    private var watchdogTimer: DispatchSourceTimer?

    init(writer: WAVWriter, targetRate: Int) {
        self.writer = writer
        self.targetRate = targetRate
    }

    func start() throws {
        // 1. Create global audio tap (captures all system audio)
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var outTapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &outTapID)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Process tap creation failed (error \(err)). Grant 'System Audio Recording Only' in System Settings > Privacy & Security.")
        }
        tapID = outTapID
        NSLog("[SystemAudioTap] Created process tap #%d", tapID)

        // 2. Read tap's audio format
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &format)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Failed to read tap format (error \(err))")
        }
        NSLog("[SystemAudioTap] Format: %.0f Hz, %d ch, %d bits, flags=0x%X",
              format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel, format.mFormatFlags)

        // 3. Get system output device UID
        var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &propSize, &outputDeviceID)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Failed to get system output device (error \(err))")
        }

        var uidCFStr: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(outputDeviceID, &uidAddr, 0, nil, &uidSize, &uidCFStr)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Failed to read device UID (error \(err))")
        }
        let outputUID = uidCFStr as String
        NSLog("[SystemAudioTap] System output device: %@", outputUID)

        // 4. Create aggregate device with the tap attached
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hlopya-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        aggregateDeviceID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Aggregate device creation failed (error \(err))")
        }
        NSLog("[SystemAudioTap] Created aggregate device #%d", aggregateDeviceID)

        // 5. Set up AVAudioConverter for high-quality resampling.
        // Sample TYPE (float vs int) comes from the tap's advertised format — that part is
        // reliable. Channel COUNT and interleaving are derived per-callback from the actual
        // buffer list instead (see processAudio): an aggregate device can re-lay-out the tap's
        // audio, and trusting the advertised channel/interleave flags is what made system.wav
        // come out at exactly half length.
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        // Authoritative input rate = the aggregate device's real operating rate. The IO proc
        // delivers frames at THIS rate; the tap's advertised rate can differ, and using a wrong
        // rate time-compresses the channel (the other way to end up with a half-length file).
        var inputRate = format.mSampleRate
        var nominalRate = Float64(0)
        var nominalSize = UInt32(MemoryLayout<Float64>.size)
        var nominalAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(aggregateDeviceID, &nominalAddr, 0, nil, &nominalSize, &nominalRate) == noErr, nominalRate > 0 {
            inputRate = nominalRate
        }

        // Mix to mono float first, then let the converter handle resampling + int16 conversion
        let monoFloatInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: true)!
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(targetRate), channels: 1, interleaved: true)!
        guard let conv = AVAudioConverter(from: monoFloatInput, to: outFmt) else {
            throw AudioCaptureError.systemAudioFailed("Failed to create audio converter")
        }
        conv.sampleRateConverterQuality = .max
        self.converter = conv
        self.inputFormat = monoFloatInput

        NSLog("[SystemAudioTap] isFloat=%d, tapFormat=%.0f Hz/%d ch, deviceRate=%.0f Hz, converter -> %.0f Hz",
              isFloat ? 1 : 0, format.mSampleRate, format.mChannelsPerFrame, inputRate, Double(targetRate))

        // 6. Start audio I/O
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }

            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !abl.isEmpty else { return }

            self.processAudio(abl: abl, isFloat: isFloat)
        }
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("IO proc creation failed (error \(err))")
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw AudioCaptureError.systemAudioFailed("Device start failed (error \(err))")
        }
        NSLog("[SystemAudioTap] Capturing system audio")

        // Watchdog: log every 3s so we can diagnose silent-capture failures
        let wd = DispatchSource.makeTimerSource(queue: queue)
        wd.schedule(deadline: .now() + 3, repeating: 3)
        wd.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("[SystemAudioTap] watchdog: callbacks=%d, samplesIn=%d, samplesOut=%d, pending=%d",
                  self.callbackCount, self.totalSamplesReceived, self.totalSamplesWritten, self.pendingSamples.count)
        }
        wd.resume()
        watchdogTimer = wd
    }

    // MARK: - Audio Processing (AVAudioConverter-based with buffering)

    private func processAudio(abl: UnsafeMutableAudioBufferListPointer, isFloat: Bool) {
        guard let firstData = abl[0].mData else { return }

        // Derive channel layout from the ACTUAL buffer list — this is the authoritative
        // description of what is really in memory. The previous code trusted the tap's
        // advertised format flags, but an aggregate device can hand the IO proc a different
        // layout (interleaved vs not, different channel count). When the advertised layout
        // disagreed with reality the frame count came out 2x off, so system.wav was written
        // at exactly half length. Buffer count + mNumberChannels never lie.
        let numBuffers = abl.count
        let nonInterleaved = numBuffers > 1
        let bufChannels = max(Int(abl[0].mNumberChannels), 1)
        let bytesPerSample = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let frameCount = nonInterleaved
            ? Int(abl[0].mDataByteSize) / bytesPerSample
            : Int(abl[0].mDataByteSize) / (bytesPerSample * bufChannels)
        guard frameCount > 0 else { return }

        if callbackCount == 0 {
            NSLog("[SystemAudioTap] First buffer: numBuffers=%d, mNumberChannels=%d, bytes=%d, frames=%d, nonInterleaved=%d, isFloat=%d, inputRate=%.0f",
                  numBuffers, Int(abl[0].mNumberChannels), Int(abl[0].mDataByteSize), frameCount,
                  nonInterleaved ? 1 : 0, isFloat ? 1 : 0, inputFormat?.sampleRate ?? 0)
        }

        // Step 1: Extract / mix to mono float
        let monoFloats = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { monoFloats.deallocate() }

        if isFloat {
            if nonInterleaved {
                let ch0 = firstData.assumingMemoryBound(to: Float.self)
                if numBuffers >= 2, let ch1Data = abl[1].mData {
                    let ch1 = ch1Data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frameCount { monoFloats[i] = (ch0[i] + ch1[i]) * 0.5 }
                } else {
                    for i in 0..<frameCount { monoFloats[i] = ch0[i] }
                }
            } else {
                let floats = firstData.assumingMemoryBound(to: Float.self)
                if bufChannels >= 2 {
                    for i in 0..<frameCount { monoFloats[i] = (floats[i * bufChannels] + floats[i * bufChannels + 1]) * 0.5 }
                } else {
                    for i in 0..<frameCount { monoFloats[i] = floats[i] }
                }
            }
        } else {
            if nonInterleaved {
                let ch0 = firstData.assumingMemoryBound(to: Int16.self)
                if numBuffers >= 2, let ch1Data = abl[1].mData {
                    let ch1 = ch1Data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frameCount { monoFloats[i] = (Float(ch0[i]) + Float(ch1[i])) / 65536.0 }
                } else {
                    for i in 0..<frameCount { monoFloats[i] = Float(ch0[i]) / 32768.0 }
                }
            } else {
                let samples = firstData.assumingMemoryBound(to: Int16.self)
                if bufChannels >= 2 {
                    for i in 0..<frameCount { monoFloats[i] = (Float(samples[i * bufChannels]) + Float(samples[i * bufChannels + 1])) / 65536.0 }
                } else {
                    for i in 0..<frameCount { monoFloats[i] = Float(samples[i]) / 32768.0 }
                }
            }
        }

        // Step 2: Accumulate into pending buffer (avoids converter boundary glitches on small chunks)
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: monoFloats, count: frameCount))

        callbackCount += 1
        totalSamplesReceived += frameCount
        if callbackCount % 500 == 1 {
            var peak: Float = 0
            for i in max(0, pendingSamples.count - frameCount)..<pendingSamples.count {
                let v = abs(pendingSamples[i])
                if v > peak { peak = v }
            }
            NSLog("[SystemAudioTap] callback #%d, received=%d, pending=%d, peak=%.4f, written=%d",
                  callbackCount, totalSamplesReceived, pendingSamples.count, peak, totalSamplesWritten)
        }

        // Step 3: Only convert when we have enough data
        guard pendingSamples.count >= minConvertFrames else { return }
        flushPendingSamples()
    }

    private func flushPendingSamples() {
        guard let converter, let inputFormat, !pendingSamples.isEmpty else { return }

        let frames = pendingSamples.count
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        if let ch0 = inputBuffer.floatChannelData?[0] {
            pendingSamples.withUnsafeBufferPointer { ptr in
                ch0.update(from: ptr.baseAddress!, count: frames)
            }
        }
        pendingSamples.removeAll(keepingCapacity: true)

        let outFrames = AVAudioFrameCount(Double(frames) * Double(targetRate) / inputFormat.sampleRate)
        guard outFrames > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outFrames) else { return }

        var consumed = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, let int16Data = outputBuffer.int16ChannelData, outputBuffer.frameLength > 0 else {
            NSLog("[SystemAudioTap] Converter failed: status=%ld, frameLength=%d", status.rawValue, outputBuffer.frameLength)
            return
        }
        totalSamplesWritten += Int(outputBuffer.frameLength)
        writer.write(samples: Data(bytes: int16Data[0], count: Int(outputBuffer.frameLength) * 2))
    }

    func stop() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            if let procID = deviceProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                deviceProcID = nil
            }
            queue.sync { self.flushPendingSamples() }
            NSLog("[SystemAudioTap] Final: callbacks=%d, samplesIn=%d, samplesOut=%d",
                  callbackCount, totalSamplesReceived, totalSamplesWritten)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
        NSLog("[SystemAudioTap] Stopped and cleaned up")
    }

    deinit { stop() }
}

// MARK: - Microphone Recorder via AVAudioEngine

final class MicRecorder {
    let writer: WAVWriter
    let engine = AVAudioEngine()
    let targetRate: Int

    init(writer: WAVWriter, targetRate: Int) {
        self.writer = writer
        self.targetRate = targetRate
    }

    func start() throws {
        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(targetRate), channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: fmt, to: outFmt)!

        node.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let outFrames = AVAudioFrameCount(Double(buf.frameLength) * Double(self.targetRate) / fmt.sampleRate)
            guard outFrames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames) else { return }

            var done = false
            converter.convert(to: out, error: nil) { _, status in
                if done { status.pointee = .noDataNow; return nil }
                done = true; status.pointee = .haveData; return buf
            }

            if let ch = out.int16ChannelData, out.frameLength > 0 {
                self.writer.write(samples: Data(bytes: ch[0], count: Int(out.frameLength) * 2))
            }
        }

        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writer.close()
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case micPermissionDenied
    case systemAudioFailed(String)

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone permission required. Go to System Settings > Privacy & Security > Microphone and enable Hlopya."
        case .systemAudioFailed(let msg):
            return msg
        }
    }
}
