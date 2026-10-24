import AppKit
import Combine
import SwiftUI
import WebKit

/// The Ovis page in the main window, under a cover while it loads or while the server does not answer.
struct WebPage: View {
    @StateObject private var page: WebPageController

    init(origin: URL, model: Model) {
        _page = StateObject(wrappedValue: WebPageController(origin: origin, model: model))
    }

    var body: some View {
        ZStack {
            WebViewHost(webView: page.webView)
            switch page.state {
            case .shown:
                EmptyView()
            case .loading:
                cover { ProgressView() }
            case let .failed(reason):
                cover {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("Waiting for Ovis to answer…", "Ovis의 응답을 기다리는 중…")).font(.headline)
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Hides the web view's empty white frame, which a dark window would flash.
    private func cover<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Typing goes to the page from the start, as it does in a browser tab.
final class OvisWebView: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// One Ovis page: the main window's, or a window the page opened (window.open, a target="_blank" link).
/// The Ovis server's own pages stay in the app; any other address goes to the default browser.
@MainActor
final class WebPageController: NSObject, ObservableObject {
    enum State: Equatable {
        case loading
        case shown
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    let webView: WKWebView
    private let origin: URL
    private weak var model: Model?
    /// The page that opened this one; nil for the main window's.
    private weak var opener: WebPageController?
    /// A popup's own window, made when its first Ovis page starts loading.
    private var window: NSWindow?
    /// Popups this page opened, kept until their window closes.
    private var popups: [WebPageController] = []
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var reloads: AnyCancellable?

    /// A popup gets the configuration WebKit hands over for it; the main window's page makes its own.
    init(origin: URL, model: Model, configuration: WKWebViewConfiguration? = nil, opener: WebPageController? = nil) {
        self.origin = origin
        self.model = model
        self.opener = opener
        webView = OvisWebView(frame: .zero, configuration: configuration ?? Self.configuration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .windowBackgroundColor
        // a popup is loaded by WebKit, with the request that opened it
        guard opener == nil else { return }
        model.page = self
        reloads = model.$reloads.dropFirst().sink { [weak self] _ in self?.reload() }
        webView.load(URLRequest(url: origin))
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // the page's sign-in cookie and its drafts stay across launches
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = userAgentSuffix
        return configuration
    }

    /// Safari's own end of the user agent, then this app's name. A web view sends neither by itself, and
    /// the terminal's Korean input goes by "Safari" (xterm.js's Hangul handling, patches/), as do the
    /// client's device names; "OvisMac" tells the client it runs in this app (src/lib/nativeApp.ts).
    /// The web view is the system's WebKit, the one the installed Safari uses, so it reports that version.
    static let userAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = safari.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "17.0"
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "Version/\(version) Safari/605.1.15 OvisMac/\(app)"
    }()

    /// Loads the page again where it is, or from the start when it is not on an Ovis page.
    func reload() {
        if state != .shown { state = .loading }
        let current = webView.url.flatMap { isOvis($0) ? $0 : nil }
        webView.load(URLRequest(url: current ?? origin))
    }

    private func isOvis(_ url: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased() && url.host?.lowercased() == origin.host?.lowercased() && url.port == origin.port
    }

    /// Another site, a mail link or another app's link. A file (one dropped where the page takes none,
    /// which would replace the page) and the page's own data stay where they are.
    private func openElsewhere(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), !["file", "data", "blob", "javascript", "about"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    private func failed(_ error: Error) {
        let error = error as NSError
        // a load stopped on purpose: a newer one, a link handed to the browser, a download
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        // WebKit's "frame load interrupted" (102) and "plug-in handled load" (204)
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
        guard opener == nil else { return }
        state = .failed(error.localizedDescription)
        model?.pageFailed()
    }

    private func showWindow() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Ovis"
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Ends a popup: its window closes, or it had none yet.
    private func closePopup() {
        if let window { window.close() } else { opener?.popups.removeAll { $0 === self } }
    }
}

extension WebPageController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // a frame inside the page (a web panel) may show any site; only the page itself is kept to Ovis
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(url.isFileURL ? .cancel : .allow)
            return
        }
        if isOvis(url) || url.absoluteString == "about:blank" {
            if opener != nil && isOvis(url) { showWindow() }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openElsewhere(url)
        // window.open() then an address elsewhere (a sign-in page): the browser has it, the popup is not needed
        if opener != nil && window == nil { closePopup() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(disposition.lowercased().hasPrefix("attachment") || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .shown
        if let window, let title = webView.title, !title.isEmpty { window.title = title }
        if opener == nil { model?.pageLoaded() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

extension WebPageController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        if let url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank", !isOvis(url) {
            openElsewhere(url)
            return nil
        }
        guard let model else { return nil }
        // an Ovis page gets a window of its own; an empty one waits for the address the page gives it
        let popup = WebPageController(origin: origin, model: model, configuration: configuration, opener: self)
        popups.append(popup)
        if let url, isOvis(url) { popup.showWindow() }
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if opener != nil { closePopup() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// Dictation in the Ovis page: macOS asks once whether the app may use the microphone
    /// (NSMicrophoneUsageDescription). Anything else, such as a site in a web panel, is asked about.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let ovis = frame.isMainFrame && origin.protocol == self.origin.scheme && origin.host == self.origin.host && origin.port == (self.origin.port ?? 0)
        decisionHandler(ovis && type == .microphone ? .grant : .prompt)
    }
}

extension WebPageController: WKDownloadDelegate {
    /// Into Downloads, as a browser saves, under a free name.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent
        let destination = Self.freeName(name.isEmpty ? "download" : name, in: folder)
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // the Dock's Downloads stack bounces, as it does for a browser's download
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: file.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        guard let window = webView.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    /// "name.ext", then "name 2.ext", "name 3.ext"…
    static func freeName(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

extension WebPageController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        opener?.popups.removeAll { $0 === self }
    }
}
