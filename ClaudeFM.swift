import AppKit
import WebKit

// YouTube's API policies forbid playing from a hidden player, separating the audio, covering the
// player or blocking its links. So this view is always on screen, takes clicks, sits in front of
// everything else in the panel, and is torn down as soon as the scene can't be seen.
final class ClaudeFM: NSObject, WKNavigationDelegate, WKUIDelegate, URLSessionTaskDelegate {
    // The stream's YouTube address changes when it restarts, and this link always points to the current one.
    private static let link = URL(string: "https://clau.de/radio")!
    private static let lastVideoKey = "claudeFMVideo"
    // YouTube requires apps to identify themselves here, because a web view sends no Referer by default.
    private static let identity = "https://github.com/Anri-Lombard/slow-horizon"

    private static let reloadSpacing = 60.0

    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var lastReload = Date.distantPast
    private(set) var webView: WKWebView?
    private var starts = 0
    private var isStarting = false
    var onFailure: (() -> Void)?

    func start(in container: NSView) {
        guard webView == nil, !isStarting else { return }
        isStarting = true
        starts += 1
        let thisStart = starts
        var request = URLRequest(url: Self.link, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { [weak self, weak container] _, response, _ in
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
            let video = location.flatMap(URL.init(string:)).flatMap(Self.videoID)
            DispatchQueue.main.async {
                guard let self, let container, thisStart == self.starts else { return }
                self.isStarting = false
                if let video { UserDefaults.standard.set(video, forKey: Self.lastVideoKey) }
                guard let chosen = video ?? UserDefaults.standard.string(forKey: Self.lastVideoKey) else {
                    self.onFailure?()
                    return
                }
                self.show(video: chosen, in: container)
            }
        }.resume()
    }

    func stop() {
        starts += 1
        isStarting = false
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // The redirect already names the stream, so there is no need to load YouTube's page to learn it.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // The embedded live player sometimes reports the stream as finished while it is still running.
    // The spacing keeps a real outage from turning into a stream of requests to YouTube.
    func reloadIfEnded() {
        guard let webView, let container = webView.superview else { return }
        webView.evaluateJavaScript("document.getElementById('movie_player')?.getPlayerState?.()") { [weak self] state, _ in
            guard let self, state as? Int == 0, webView === self.webView, Date().timeIntervalSince(self.lastReload) > Self.reloadSpacing else { return }
            self.lastReload = Date()
            self.stop()
            self.start(in: container)
        }
    }

    private static func videoID(from url: URL) -> String? {
        guard url.host?.hasSuffix("youtube.com") == true else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return query?.first { $0.name == "v" }?.value ?? (url.pathComponents.contains("live") ? url.lastPathComponent : nil)
    }

    private func show(video: String, in container: NSView) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: container.bounds, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.uiDelegate = self
        container.addSubview(view)
        webView = view

        var components = URLComponents(string: "https://www.youtube.com/embed/\(video)")!
        components.queryItems = [URLQueryItem(name: "autoplay", value: "1"), URLQueryItem(name: "origin", value: Self.identity)]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.identity, forHTTPHeaderField: "Referer")
        view.load(request)
    }

    // Links in the player leave for the browser, so the stream keeps its place on this display.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        if action.navigationType == .linkActivated && isMainFrame, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}
