import Foundation

/// Waveforms for voice notes that arrived without one.
///
/// The waveform is never transmitted — it is not in the wire format, and
/// nothing on the receive path sets it — so `audioWaveform` is nil on every
/// voice note anyone sends you. The bubble drew an empty gap where the bars
/// should be, and only your own sent notes had any.
///
/// Decoded from the audio itself rather than added to the wire format: it
/// needs no schema change and no coordination with Android, and it works for
/// messages that were already delivered. Signal does the same.
actor VoiceWaveformCache {

    static let shared = VoiceWaveformCache()

    /// Readable without awaiting, so a bubble coming back on screen can draw
    /// its bars in the first frame rather than showing a flat placeholder and
    /// filling in afterwards. An actor can only be read from an async context,
    /// and a `.task` runs after the view has already been drawn once.
    private static let sync = SyncStore()

    private var inFlight: [String: Task<[Float], Never>] = [:]

    /// The waveform if it is already known. Nil means it has not been decoded
    /// yet, not that there is none.
    nonisolated static func cached(for url: URL) -> [Float]? {
        sync.value(forKey: url.path)
    }

    private final class SyncStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: [Float]] = [:]

        func value(forKey key: String) -> [Float]? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func set(_ value: [Float], forKey key: String) {
            lock.lock()
            storage[key] = value
            lock.unlock()
        }
    }

    /// Decoding is a few hundred milliseconds of work per clip, and cells are
    /// recycled constantly while scrolling; without this a transcript of voice
    /// notes decodes the same audio over and over.
    func waveform(for url: URL, bins: Int = 64) async -> [Float] {
        let key = url.path
        if let cached = Self.sync.value(forKey: key) { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<[Float], Never> {
            (try? await VoiceWaveformDecoder.decode(url: url, bins: bins)) ?? []
        }
        inFlight[key] = task
        let samples = await task.value
        inFlight[key] = nil
        // A failure is cached too. The file is not going to become decodable,
        // and retrying on every cell reuse would be worse than a flat bar.
        Self.sync.set(samples, forKey: key)
        return samples
    }
}
