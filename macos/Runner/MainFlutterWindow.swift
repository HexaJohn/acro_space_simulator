import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // DISABLED for now — standard window chrome instead. Re-enable by
    // uncommenting the block below.
    //
    // macOS 26 (Tahoe) scales a window's corner radius to its toolbar: no
    // toolbar leaves the modest default radius, a `.unified` (tall) toolbar
    // gets the large concentric one. We want the radius, not the chrome — so
    // attach an item-less toolbar and suppress everything that draws. The
    // transparent titlebar + full-size content view let the flutter_scene
    // viewport run edge to edge underneath, and the window clips it to the
    // rounded corners for free.
    //
    // let toolbar = NSToolbar(identifier: "AcroChromelessToolbar")
    // self.toolbar = toolbar
    // self.toolbarStyle = .unified
    // self.titleVisibility = .hidden
    // self.titlebarAppearsTransparent = true
    // self.styleMask.insert(.fullSizeContentView)

    super.awakeFromNib()
  }
}
