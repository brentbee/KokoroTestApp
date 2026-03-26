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
        // Completion handled by async download(from:) return value
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

/// The view model that manages text-to-speech functionality using the Kokoro TTS engine.
final class TestAppModel: ObservableObject {
    /// The Kokoro text-to-speech engine instance (nil until model is downloaded)
    var kokoroTTSEngine: KokoroTTS?

    /// The audio engine used for playback
    let audioEngine: AVAudioEngine

    /// The audio player node attached to the audio engine
    let playerNode: AVAudioPlayerNode

    /// Dictionary of available voices, mapped by voice name to MLX array data
    var voices: [String: MLXArray] = [:]

    /// Array of voice names available for selection in the UI
    @Published var voiceNames: [String] = []

    /// The currently selected voice name
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

    /// Initializes the test app model with audio components and starts model download.
    init() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)

        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up AVAudioSession: \(error.localizedDescription)")
        }
        #endif

        Task { await downloadAndLoadModel() }
    }

    /// Downloads the model from Hugging Face (if not cached) and initializes the TTS engine.
    func downloadAndLoadModel() async {
        if FileManager.default.fileExists(atPath: modelCachePath.path) {
            loadModelFromDisk()
            return
        }

        loadingState = .downloading(progress: 0)

        do {
            let tracker = DownloadProgressTracker { [weak self] progress in
                Task { @MainActor in
                    self?.loadingState = .downloading(progress: progress)
                }
            }

            let session = URLSession(configuration: .default, delegate: tracker, delegateQueue: nil)
            let (tempURL, _) = try await session.download(from: Self.modelURL)

            if FileManager.default.fileExists(atPath: modelCachePath.path) {
                try FileManager.default.removeItem(at: modelCachePath)
            }
            try FileManager.default.moveItem(at: tempURL, to: modelCachePath)
            session.invalidateAndCancel()

            loadModelFromDisk()
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    private func loadModelFromDisk() {
        loadingState = .loadingModel

        kokoroTTSEngine = KokoroTTS(modelPath: modelCachePath)

        let voiceFilePath = Bundle.main.url(forResource: "voices", withExtension: "npz")!
        voices = NpyzReader.read(fileFromPath: voiceFilePath) ?? [:]

        voiceNames = voices.keys.map { String($0.split(separator: ".")[0]) }.sorted(by: <)
        selectedVoice = voiceNames.first ?? ""

        loadingState = .ready
    }

    /// Converts the provided text to speech and plays it through the audio engine.
    func say(_ text: String) {
        guard let kokoroTTSEngine else { return }

        let (audio, tokenArray) = try! kokoroTTSEngine.generateAudio(
            voice: voices[selectedVoice + ".npy"]!,
            language: selectedVoice.first! == "a" ? .enUS : .enGB,
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

        do {
            try audioEngine.start()
        } catch {
            print("Audio engine failed to start: \(error.localizedDescription)")
            return
        }

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
    }
}
