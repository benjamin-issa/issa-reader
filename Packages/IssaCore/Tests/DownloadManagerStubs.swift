import Foundation

@testable import IssaCore

/// A file server for download tests, answering by the host a request names.
///
/// Stateless on purpose: swift-testing runs suites in parallel, and a stub that
/// held its next answer in static state would let one test answer another's
/// request. The host says what comes back — `epub.download.test` a zip's first
/// bytes, `html.download.test` a sign-in page, and so on — always with a 200,
/// which is the case a download used to take at its word.
final class DownloadStubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: String, Sendable, CaseIterable {
        case epub, html, json, audio

        var contentType: String {
            switch self {
            case .epub: "application/epub+zip"
            case .html: "text/html; charset=utf-8"
            case .json: "application/json"
            case .audio: "audio/mp4"
            }
        }

        var body: Data {
            switch self {
            case .epub: DownloadStubProtocol.zipHead
            case .html: DownloadStubProtocol.page
            case .json: Data(#"{"message":"Not signed in"}"#.utf8)
            // The first box of an MP4: whatever an audiobook is, it is not a zip.
            case .audio: Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypM4A ".utf8)
            }
        }
    }

    /// How every EPUB begins: a zip's local file header, then the `mimetype`
    /// entry the format requires first.
    static let zipHead = Data([0x50, 0x4B, 0x03, 0x04]) + Data("mimetypeapplication/epub+zip".utf8)
    /// What a proxy or a captive portal sends in place of the file.
    static let page = Data("<!doctype html><html><body>Sign in to continue</body></html>".utf8)

    /// The server to point a client at for one kind of answer.
    static func base(_ answer: Answer) -> URL {
        URL(string: "http://\(answer.rawValue).download.test")!
    }

    /// A session every request of which this answers, and never the network.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    /// A download task that has run to completion here, so it carries a real
    /// HTTP response — the one thing a task made by hand cannot, and the thing
    /// a finished transfer is judged by.
    static func finishedTask(_ answer: Answer) async -> URLSessionDownloadTask {
        let session = session()
        var finished: URLSessionDownloadTask?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let task = session.downloadTask(with: base(answer).appending(path: "file")) { _, _, _ in
                continuation.resume()
            }
            finished = task
            task.resume()
        }
        return finished!
    }

    /// Writes what a transfer of this kind leaves in the system's temporary
    /// file, for a test to hand to the finished-download callback.
    static func arrivedFile(_ answer: Answer, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "arrived-\(UUID().uuidString).tmp")
        try answer.body.write(to: url)
        return url
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let name = url.host()?.split(separator: ".").first,
              let answer = Answer(rawValue: String(name))
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": answer.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Waits for main-actor state a delegate callback writes through a hop, for a
/// bounded time. The callbacks run on the session's queue and publish with
/// `Task { @MainActor in … }`, so a test that asserts at once can beat them.
@MainActor
func settle(until condition: () -> Bool) async {
    for _ in 0 ..< 400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A server address no request reaches. TEST-NET-1 (RFC 5737) is reserved for
/// documentation and routes nowhere, so a real task started against it waits
/// to connect rather than failing fast — `example.test` failed on the first
/// DNS answer, and a real failure arriving inside a test raced the callbacks
/// the test was standing in for.
let unreachableServer = URL(string: "http://192.0.2.1")!
