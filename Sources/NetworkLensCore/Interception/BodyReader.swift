import Foundation

/// Reads request bodies, including stream-based ones, under a byte cap.
///
/// `httpBody` is `nil` for anything built by a multipart encoder or by
/// `uploadTask(with:fromFile:)` — those expose `httpBodyStream` instead. Without
/// this, POST bodies silently show as empty and the tool looks broken.
///
/// The cap matters: a video upload would otherwise be copied into memory in its
/// entirety just to be displayed in a debug list.
public enum BodyReader {

    public struct Result: Sendable {
        public var data: Data
        /// True when the source had more bytes than the cap allowed.
        public var truncated: Bool
        /// Full size when it could be determined without exceeding the cap.
        public var originalByteCount: Int?
    }

    /// Chunk size for stream draining. Small enough not to over-allocate for a
    /// tiny body, large enough not to syscall per byte.
    private static let chunkSize = 16 * 1024

    /// Prefers `httpBody`, falls back to draining `httpBodyStream`.
    public static func read(from request: URLRequest, cap: Int) -> Result? {
        if let body = request.httpBody {
            guard body.count > cap else {
                return Result(data: body, truncated: false, originalByteCount: body.count)
            }
            return Result(
                data: body.prefix(cap),
                truncated: true,
                originalByteCount: body.count
            )
        }
        guard let stream = request.httpBodyStream else { return nil }
        return drain(stream, cap: cap)
    }

    /// Reads a stream into memory, stopping at `cap`.
    ///
    /// The stream is consumed by this — a consumed stream cannot be re-sent, so
    /// the caller must put the materialised `Data` back on the request before
    /// it goes to the network.
    public static func drain(_ stream: InputStream, cap: Int) -> Result {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var truncated = false

        while stream.hasBytesAvailable {
            let wanted = min(chunkSize, max(0, cap - data.count))
            if wanted == 0 {
                // At the cap. One more read tells us whether anything remains,
                // so `truncated` is accurate rather than assumed.
                let extra = stream.read(&buffer, maxLength: 1)
                truncated = extra > 0
                break
            }
            let read = stream.read(&buffer, maxLength: wanted)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return Result(
            data: data,
            truncated: truncated,
            originalByteCount: truncated ? nil : data.count
        )
    }

    /// Materialises a stream body onto the request so it can be sent.
    ///
    /// Only safe when the whole body fit under the cap — a truncated body would
    /// silently send fewer bytes than the app intended, so the request is left
    /// untouched in that case and the stream is preserved.
    public static func materialisingStreamBody(
        in request: URLRequest,
        cap: Int
    ) -> (request: URLRequest, capture: Result?) {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return (request, read(from: request, cap: cap))
        }
        let result = drain(stream, cap: cap)
        guard !result.truncated else {
            // Cannot re-send a consumed stream and cannot send a partial body.
            // Report the capture, leave the request alone: URLSession still has
            // its own copy of the original stream.
            return (request, result)
        }

        var materialised = request
        materialised.httpBodyStream = nil
        materialised.httpBody = result.data
        materialised.setValue("\(result.data.count)", forHTTPHeaderField: "Content-Length")
        return (materialised, result)
    }
}
