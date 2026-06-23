import AVFoundation

/// Convert an arbitrary audio file into a Chatterbox reference clip:
/// mono, 24 kHz, 16-bit WAV, trimmed to a sane length.
enum AudioImport {
    enum Err: Error { case open, convert, write }

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
        try? FileManager.default.removeItem(at: dest)
        let outFile = try AVAudioFile(forWriting: dest, settings: settings)
        let writeFormat = outFile.processingFormat   // float32, 24 kHz, mono

        guard let converter = AVAudioConverter(from: inFormat, to: writeFormat) else { throw Err.convert }

        let maxFrames = AVAudioFramePosition(maxSeconds * inFormat.sampleRate)
        let chunk: AVAudioFrameCount = 16384
        var done = false
        var written: AVAudioFramePosition = 0

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
        if written == 0 { throw Err.write }
    }
}
