#if DEBUG
import Foundation

/// For recording demos only (`GNV_DEV_ALIAS=shown.example.com=real.host`):
/// the app talks to "shown.example.com" and this sends each request to the
/// real host, writing the shown name back into what the server answers. So
/// a recording shows no internal host name. Git is pointed the same way with
/// `url.<real>.insteadOf` in the environment the app is started with.
final class DemoAlias: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var shown = ""
    nonisolated(unsafe) static var real = ""
    private static let handled = "gnv.demo-alias"
    private static let inner = URLSession(configuration: .ephemeral)
    private var forwarding: URLSessionDataTask?

    static func install(_ value: String) {
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        shown = parts[0]
        real = parts[1]
        URLProtocol.registerClass(DemoAlias.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == shown && property(forKey: handled, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.host = Self.real
        var forwarded = request
        forwarded.url = parts.url
        if let mutable = (forwarded as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
            URLProtocol.setProperty(true, forKey: Self.handled, in: mutable)
            forwarded = mutable as URLRequest
        }
        forwarding = Self.inner.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            var body = data ?? Data()
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if type.contains("json") || type.contains("text"), let text = String(data: body, encoding: .utf8) {
                body = Data(text.replacingOccurrences(of: Self.real, with: Self.shown).utf8)
            }
            var headers = http?.allHeaderFields as? [String: String] ?? [:]
            headers["Content-Length"] = String(body.count)
            headers["Content-Encoding"] = nil
            let answer = HTTPURLResponse(url: url, statusCode: http?.statusCode ?? 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwarding?.resume()
    }

    override func stopLoading() { forwarding?.cancel() }
}
#endif
