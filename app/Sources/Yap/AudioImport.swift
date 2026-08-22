import AVFoundation

/// Convert an arbitrary audio file into a Pocket reference clip:
/// mono, 24 kHz, 16-bit WAV, trimmed to a sane length.
enum AudioImport {
    enum Err: Error { case open, convert, write }

    /// Convert `src` and put the result at `dest`.
    ///
    /// **Never touches `dest` until the replacement is complete and readable.**
    /// The first version removed `dest` up front and then converted straight into
    /// it, so importing a new take under an existing name destroyed the user's
    /// cloned voice the moment the decode, conversion or write failed — leaving
    /// no old voice and no new one. Staging + rename means a failure anywhere
    /// leaves the existing voice exactly as it was.
    static func toReferenceWAV(src: URL, dest: URL, maxSeconds: Double = 20) throws {
        let inFile = try AVAudioFile(forReading: src)
        let inFormat = inFile.processingFormat

        // The file on disk is 16-bit PCM mono @ 24 kHz (these settings). But
        // AVAudioFile.write() expects buffers in the file's *processingFormat*
        // (a standard non-interleaved float format) and converts to Int16 on
        // disk itself. Feeding it an Int16/interleaved buffer instead trips a
        // CoreAudio assertion and SIGTRAPs — so we convert into processingFormat.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A scratch dir guaranteed to be on the same volume as `dest`, so the
        // final rename is an atomic in-place swap rather than a copy+delete.
        // Deliberately NOT inside hd-voices: the backend lists that directory
        // with `*.wav`, and a temp left behind by a crash would show up as a
        // phantom voice.
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                               appropriateFor: dest, create: true)
        defer { try? fm.removeItem(at: stage) }
        // Keep the .wav extension — AVAudioFile picks the container from it.
        let tmp = stage.appending(path: dest.lastPathComponent)

        var written: AVAudioFramePosition = 0
        // Scoped so `outFile` is released — and the WAV header finalized — before
        // we validate and rename. AVAudioFile only closes the file on deinit.
        do {
            let outFile = try AVAudioFile(forWriting: tmp, settings: settings)
            let writeFormat = outFile.processingFormat   // float32, 24 kHz, mono

            guard let converter = AVAudioConverter(from: inFormat, to: writeFormat) else { throw Err.convert }

            let maxFrames = AVAudioFramePosition(maxSeconds * inFormat.sampleRate)
            let chunk: AVAudioFrameCount = 16384
            var done = false

            while !done && written < maxFrames {
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw Err.convert }
                try inFile.read(into: inBuf, frameCount: chunk)
                if inBuf.frameLength == 0 { break }
                written += AVAudioFramePosition(inBuf.frameLength)

                let ratio = writeFormat.sampleRate / inFormat.sampleRate
                let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: cap) else { throw Err.convert }
                var fed = false
                var err: NSError?
                converter.convert(to: outBuf, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return inBuf
                }
                if err != nil { throw Err.convert }
                if outBuf.frameLength > 0 { try outFile.write(from: outBuf) }
                if inFile.framePosition >= inFile.length { done = true }
            }
        }
        if written == 0 { throw Err.write }
        // Prove the staged clip is a readable, non-empty WAV before it is allowed
        // to replace a working voice.
        guard let check = try? AVAudioFile(forReading: tmp), check.length > 0 else { throw Err.write }

        // rename(2) is atomic and replaces `dest` in one step, so nothing ever
        // observes a missing or half-written voice file.
        guard rename(tmp.path, dest.path) == 0 else { throw Err.write }
    }
}
