import AVFoundation
import MLX
import SwiftUI
import KokoroSwift
import Combine
import MLXUtilsLibrary

enum LoadingState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case loadingModel
    case ready
    case error(String)
}

private final class DownloadProgressTracker: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

/// The view model that manages text-to-speech functionality using the Kokoro TTS engine.
final class TestAppModel: ObservableObject {
    var kokoroTTSEngine: KokoroTTS?
    var audioEngine: AVAudioEngine?
    var playerNode: AVAudioPlayerNode?
    var voices: [String: MLXArray] = [:]

    @Published var voiceNames: [String] = []
    @Published var selectedVoice: String = ""
    @Published var stringToFollowTheAudio: String = ""
    @Published var loadingState: LoadingState = .notStarted

    var timer: Timer?

    private static let modelURL = URL(string: "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    private static let modelFilename = "kokoro-v1_0.safetensors"

    private var modelCachePath: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(Self.modelFilename)
    }

    init() {
        // Deliberately minimal init - no framework initialization here
        // Everything deferred to downloadAndLoadModel() via Task
        print("[KokoroTest] TestAppModel init - starting download task")
        Task { await downloadAndLoadModel() }
    }

    func downloadAndLoadModel() async {
        print("[KokoroTest] downloadAndLoadModel started")
        print("[KokoroTest] Cache path: \(modelCachePath.path)")

        if FileManager.default.fileExists(atPath: modelCachePath.path) {
            print("[KokoroTest] Model found in cache, loading from disk")
            loadModelFromDisk()
            return
        }

        loadingState = .downloading(progress: 0)
        print("[KokoroTest] Starting download from HuggingFace")

        do {
            let tracker = DownloadProgressTracker { [weak self] progress in
                Task { @MainActor in
                    self?.loadingState = .downloading(progress: progress)
                }
            }

            let session = URLSession(configuration: .default, delegate: tracker, delegateQueue: nil)
            let (tempURL, response) = try await session.download(from: Self.modelURL)

            let httpResponse = response as? HTTPURLResponse
            print("[KokoroTest] Download complete, status: \(httpResponse?.statusCode ?? -1)")

            if let status = httpResponse?.statusCode, status != 200 {
                loadingState = .error("Download failed with HTTP \(status)")
                session.invalidateAndCancel()
                return
            }

            if FileManager.default.fileExists(atPath: modelCachePath.path) {
                try FileManager.default.removeItem(at: modelCachePath)
            }
            try FileManager.default.moveItem(at: tempURL, to: modelCachePath)
            session.invalidateAndCancel()

            let attrs = try FileManager.default.attributesOfItem(atPath: modelCachePath.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            print("[KokoroTest] Model saved, size: \(fileSize) bytes")

            if fileSize < 1_000_000 {
                loadingState = .error("Downloaded file too small (\(fileSize) bytes) - likely not a valid model")
                try? FileManager.default.removeItem(at: modelCachePath)
                return
            }

            loadModelFromDisk()
        } catch {
            print("[KokoroTest] Download error: \(error)")
            loadingState = .error("Download failed: \(error.localizedDescription)")
        }
    }

    private func loadModelFromDisk() {
        loadingState = .loadingModel
        print("[KokoroTest] Loading model from disk...")

        // Configure MLX GPU settings
        GPU.set(cacheLimit: 50 * 1024 * 1024)
        GPU.set(memoryLimit: 900 * 1024 * 1024)
        print("[KokoroTest] GPU limits configured")

        // Initialize TTS engine
        kokoroTTSEngine = KokoroTTS(modelPath: modelCachePath)
        print("[KokoroTest] KokoroTTS engine initialized")

        // Load voices from bundle
        guard let voiceFilePath = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            print("[KokoroTest] ERROR: voices.npz not found in bundle!")
            loadingState = .error("voices.npz not found in app bundle")
            return
        }

        print("[KokoroTest] Loading voices from: \(voiceFilePath.path)")
        voices = NpyzReader.read(fileFromPath: voiceFilePath) ?? [:]

        if voices.isEmpty {
            print("[KokoroTest] ERROR: No voices loaded from npz file")
            loadingState = .error("Failed to load voice data")
            return
        }

        voiceNames = voices.keys.map { String($0.split(separator: ".")[0]) }.sorted(by: <)
        selectedVoice = voiceNames.first ?? ""
        print("[KokoroTest] Loaded \(voiceNames.count) voices, selected: \(selectedVoice)")

        // Set up audio engine
        setupAudioEngine()

        loadingState = .ready
        print("[KokoroTest] Model ready!")
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        if let audioEngine, let playerNode {
            audioEngine.attach(playerNode)
        }

        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("[KokoroTest] Failed to set up AVAudioSession: \(error.localizedDescription)")
        }
        #endif
    }

    func say(_ text: String) {
        guard let kokoroTTSEngine, let audioEngine, let playerNode else {
            print("[KokoroTest] Engine not ready")
            return
        }

        guard let voiceData = voices[selectedVoice + ".npy"] else {
            print("[KokoroTest] Voice data not found for: \(selectedVoice)")
            return
        }

        let language: Language = selectedVoice.first == "a" ? .enUS : .enGB

        do {
            let (audio, tokenArray) = try kokoroTTSEngine.generateAudio(
                voice: voiceData,
                language: language,
                text: text
            )

            if let tokenArray {
                for t in tokenArray {
                    print("\(t.text): \(t.start_ts, default: "UNK") - \(t.end_ts, default: "UNK")")
                }
            }

            let sampleRate = Double(KokoroTTS.Constants.samplingRate)
            let audioLength = Double(audio.count) / sampleRate
            print("Audio Length: " + String(format: "%.4f", audioLength))
            print("Real Time Factor: " + String(format: "%.2f", audioLength / (BenchmarkTimer.getTimeInSec(KokoroTTS.Constants.bm_TTS) ?? 1.0)))

            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else {
                print("Couldn't create buffer")
                return
            }

            buffer.frameLength = buffer.frameCapacity
            let channels = buffer.floatChannelData!
            let dst: UnsafeMutablePointer<Float> = channels[0]

            audio.withUnsafeBufferPointer { buf in
                precondition(buf.baseAddress != nil)
                let byteCount = buf.count * MemoryLayout<Float>.stride
                UnsafeMutableRawPointer(dst)
                    .copyMemory(from: UnsafeRawPointer(buf.baseAddress!), byteCount: byteCount)
            }

            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

            try audioEngine.start()

            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            playerNode.play()

            if let tokenArray {
                stringToFollowTheAudio = ""
                var currentToken = 0
                var audioTime: Double = 0.0
                var added = false

                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                    guard let self else { return }
                    audioTime += 0.1

                    guard currentToken < tokenArray.count else {
                        timer.invalidate()
                        return
                    }

                    let token = tokenArray[currentToken]

                    if !added, let start = token.start_ts, start < audioTime {
                        stringToFollowTheAudio += token.text + (token.whitespace.isEmpty ? "" : " ")
                        added = true
                    }

                    if let end = token.end_ts, audioTime >= end {
                        currentToken += 1
                        added = false
                    }
                }
            }
        } catch {
            print("[KokoroTest] TTS generation error: \(error)")
        }
    }
}
