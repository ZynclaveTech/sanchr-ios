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

    private var cache: [String: [Float]] = [:]
    private var inFlight: [String: Task<[Float], Never>] = [:]

    /// Decoding is a few hundred milliseconds of work per clip, and cells are
    /// recycled constantly while scrolling; without this a transcript of voice
    /// notes decodes the same audio over and over.
    func waveform(for url: URL, bins: Int = 64) async -> [Float] {
        let key = url.path
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<[Float], Never> {
            (try? await VoiceWaveformDecoder.decode(url: url, bins: bins)) ?? []
        }
        inFlight[key] = task
        let samples = await task.value
        inFlight[key] = nil
        // A failure is cached too. The file is not going to become decodable,
        // and retrying on every cell reuse would be worse than a flat bar.
        cache[key] = samples
        return samples
    }
}
