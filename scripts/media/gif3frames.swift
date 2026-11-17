import AppKit
import WebKit
// Lädt gif3.html einmal und fotografiert render(t) für jedes Bild (2x)
let a = CommandLine.arguments
let html = URL(fileURLWithPath: a[1]), outDir = a[2], fps = Double(a[3])!
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let cfg = WKWebViewConfiguration()
cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 880, height: 550), configuration: cfg)
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 880, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
win.backingType = .buffered
win.contentView = web
final class Del: NSObject, WKNavigationDelegate {
    var times: [Double] = []
    var i = 0
    func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            v.evaluateJavaScript("window.DURATION") { r, _ in
                let dur = (r as? Double) ?? 19.3
                self.times = a.count > 4 ? a[4].split(separator: ",").map { Double($0)! } : stride(from: 0.0, to: dur, by: 1 / fps).map { $0 }
                self.next(v)
            }
        }
    }
    func next(_ v: WKWebView) {
        guard i < times.count else { exit(0) }
        v.evaluateJavaScript("render(\(times[i]))") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                let c = WKSnapshotConfiguration()
                c.snapshotWidth = 880
                v.takeSnapshot(with: c) { img, _ in
                    if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(outDir)/f\(String(format: "%04d", self.i)).png"))
                    }
                    self.i += 1
                    self.next(v)
                }
            }
        }
    }
}
let d = Del()
web.navigationDelegate = d
web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
app.run()
