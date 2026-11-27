import Foundation
import Network

struct OAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

/// A one-shot HTTP listener on 127.0.0.1 that catches Google's OAuth redirect
/// (the "loopback IP address" flow Google recommends for desktop apps).
/// All mutable state is touched only on `queue`.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Daymark.LoopbackServer")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var pending: Result<OAuthCallback, Error>?
    private var finished = false
    private var startResumed = false
    /// Only a callback carrying this OAuth `state` ends the flow; anything else on the port
    /// (another local process, a stray browser request) gets a 400 and is ignored.
    private let expectedState: String?

    init(expectedState: String? = nil) {
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [self] state in
                guard !startResumed else { return }
                switch state {
                case .ready:
                    startResumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e), .waiting(let e):
                    // .waiting means the port can't be opened right now (e.g. blocked by macOS);
                    // fail instead of leaving the sign-in hanging forever.
                    startResumed = true
                    listener.cancel()
                    cont.resume(throwing: e)
                case .cancelled:
                    startResumed = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthCallback, Error>) in
                queue.async {
                    if let p = self.pending {
                        self.pending = nil
                        self.finished = true
                        cont.resume(with: p)
                        return
                    }
                    self.continuation = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finish(.failure(OAuthError.timedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Private (on queue)

    private func finish(_ r: Result<OAuthCallback, Error>) {
        guard !finished else { return }
        if let c = continuation {
            continuation = nil
            finished = true
            c.resume(with: r)
        } else if pending == nil {
            pending = r
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            func value(_ n: String) -> String? { items.first { $0.name == n }?.value }

            let code = value("code"), error = value("error")
            guard code != nil || error != nil else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            if let expected = self.expectedState, value("state") != expected {
                self.respond(conn, status: "400 Bad Request", body: "")
                return
            }
            self.respond(conn, status: "200 OK", body: Self.page(success: code != nil))
            self.finish(.success(OAuthCallback(code: code, state: value("state"), error: error)))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func page(success: Bool) -> String {
        let msg = success
            ? "Signed in. You can close this tab and return to Daymark."
            : "Sign-in was cancelled. You can close this tab."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Daymark</title>
        <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:90vh;color:#202124}
        @media(prefers-color-scheme:dark){body{background:#202124;color:#e8eaed}}</style></head>
        <body><p>\(msg)</p><script>setTimeout(()=>window.close(),800)</script></body></html>
        """
    }
}
