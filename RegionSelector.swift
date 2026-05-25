import Cocoa

// MARK: - 录制区域选择框（固定比例录制时框选要录的区域，支持多显示器）
//
// 选择窗口覆盖「所有显示器的联合区域」，区域框可拖到任意一块屏；
// 但任一时刻完整吸附在「框中心所在的那块屏」内（因为一次只能录一块屏）。
// 两种模式：editing（半透明遮罩+手柄，可拖动调整）/ recording（虚线指示、鼠标穿透、不被录进去）。

final class RegionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class RegionView: NSView {
    enum Mode { case editing, recording }
    var mode: Mode = .editing
    var aspect: CGFloat = 9.0 / 16.0          // 宽/高
    var region: CGRect = .zero                // 本视图坐标（左下原点）
    var screenFramesLocal: [CGRect] = []      // 各屏在本视图坐标的 frame
    var mainScreenLocal: CGRect = .zero
    var onChange: ((CGRect) -> Void)?

    private enum Drag { case none, move, resizeBR }
    private var drag: Drag = .none
    private var startMouse = CGPoint.zero
    private var startRegion = CGRect.zero
    private let handle: CGFloat = 16
    private let minW: CGFloat = 160

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetCentered() {
        let scr = mainScreenLocal.width > 1 ? mainScreenLocal : bounds
        var w = scr.width * 0.6
        var h = w / aspect
        if h > scr.height * 0.85 { h = scr.height * 0.85; w = h * aspect }
        region = CGRect(x: scr.midX - w / 2, y: scr.midY - h / 2, width: w, height: h)
        needsDisplay = true
        onChange?(region)
    }

    private func centerScreen() -> CGRect {
        let c = CGPoint(x: region.midX, y: region.midY)
        return screenFramesLocal.first { $0.contains(c) } ?? mainScreenLocal
    }

    /// 把区域吸附进「中心所在屏」内（保持比例）
    private func clampToCenterScreen() {
        let scr = centerScreen()
        guard scr.width > 1 else { return }
        var r = region
        if r.width > scr.width { r.size = CGSize(width: scr.width, height: scr.width / aspect) }
        if r.height > scr.height { r.size = CGSize(width: scr.height * aspect, height: scr.height) }
        r.origin.x = min(max(scr.minX, r.minX), scr.maxX - r.width)
        r.origin.y = min(max(scr.minY, r.minY), scr.maxY - r.height)
        region = r
    }

    override func draw(_ dirtyRect: NSRect) {
        if mode == .recording {
            // 虚线指示框（窗口被排除，不会录进去）
            let path = NSBezierPath(rect: region.insetBy(dx: -2, dy: -2))
            path.lineWidth = 3
            path.setLineDash([10, 6], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
            let tag = "● 录制区域"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
            let sz = (tag as NSString).size(withAttributes: attrs)
            let bg = CGRect(x: region.minX, y: region.maxY + 4, width: sz.width + 12, height: sz.height + 6)
            NSColor(red: 0.8, green: 0, blue: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
            (tag as NSString).draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 3), withAttributes: attrs)
            return
        }

        // editing：框外遮罩（even-odd 镂空框内）
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: region))
        mask.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.38).setFill()
        mask.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: region); border.lineWidth = 2; border.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: brHandleRect()).fill()

        let scale = window?.backingScaleFactor ?? 2
        let label = String(format: "%d × %d", Int(region.width * scale), Int(region.height * scale))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let sz = (label as NSString).size(withAttributes: attrs)
        let bg = CGRect(x: region.midX - sz.width / 2 - 6, y: region.maxY + 6,
                        width: sz.width + 12, height: sz.height + 6)
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 3), withAttributes: attrs)
    }

    private func brHandleRect() -> CGRect {
        CGRect(x: region.maxX - handle / 2, y: region.minY - handle / 2, width: handle, height: handle)
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .editing else { return }
        let p = convert(event.locationInWindow, from: nil)
        startMouse = p; startRegion = region
        if brHandleRect().insetBy(dx: -6, dy: -6).contains(p) { drag = .resizeBR }
        else if region.contains(p) { drag = .move }
        else { drag = .none }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .editing else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        switch drag {
        case .move:
            region = CGRect(x: startRegion.minX + dx, y: startRegion.minY + dy,
                            width: startRegion.width, height: startRegion.height)
            clampToCenterScreen()
        case .resizeBR:
            let scr = centerScreen()
            let anchorX = startRegion.minX
            let anchorTop = startRegion.maxY
            var w = max(minW, (startMouse.x + dx) - anchorX)
            var h = w / aspect
            if anchorTop - h < scr.minY { h = anchorTop - scr.minY; w = h * aspect }
            if anchorX + w > scr.maxX { w = scr.maxX - anchorX; h = w / aspect }
            region = CGRect(x: anchorX, y: anchorTop - h, width: w, height: h)
        case .none:
            break
        }
        needsDisplay = true
        onChange?(region)
    }

    override func mouseUp(with event: NSEvent) { drag = .none }
}

final class RegionController {
    private var window: RegionWindow?
    private var view: RegionView?
    private(set) var screen: NSScreen = NSScreen.main ?? NSScreen.screens.first!
    private var onChange: ((CGRect) -> Void)?

    /// 区域（全局 Cocoa 坐标，左下原点）
    var regionGlobal: CGRect {
        guard let v = view else { return .zero }
        return v.region.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }
    var displayID: CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    var windowID: CGWindowID? {
        guard let w = window, w.windowNumber > 0 else { return nil }
        return CGWindowID(w.windowNumber)
    }

    /// 区域选择窗口覆盖单块屏（避免跨屏窗口的坐标问题）；换屏用菜单切换 screen 重新 show
    func show(aspectWH: CGFloat, on screen: NSScreen?, onChange: @escaping (CGRect) -> Void) {
        self.screen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        self.onChange = onChange
        let f = self.screen.frame
        if window == nil {
            let w = RegionWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let v = RegionView(frame: NSRect(origin: .zero, size: f.size))
            v.onChange = { [weak self] _ in self?.onChange?(self?.regionGlobal ?? .zero) }
            w.contentView = v
            window = w; view = v
        }
        window?.setFrame(f, display: true)
        let local = CGRect(origin: .zero, size: f.size)
        view?.frame = local
        view?.screenFramesLocal = [local]
        view?.mainScreenLocal = local
        view?.aspect = aspectWH
        view?.mode = .editing
        view?.resetCentered()
        window?.ignoresMouseEvents = false
        window?.orderFront(nil)
    }

    /// 切换录制指示模式：虚线 + 鼠标穿透（且窗口要被加入 SCStream 的排除列表）
    func setRecordingMode(_ recording: Bool) {
        view?.mode = recording ? .recording : .editing
        window?.ignoresMouseEvents = recording
        view?.needsDisplay = true
        if window?.isVisible == false { window?.orderFront(nil) }
    }

    func hide() { window?.orderOut(nil) }

    /// 区域换算成 display-local 左上原点的 points 矩形（SCStreamConfiguration.sourceRect）
    func sourceRect() -> CGRect {
        let g = regionGlobal
        let sf = screen.frame
        let localX = g.minX - sf.minX
        let localYBottom = g.minY - sf.minY
        let localYTop = sf.height - (localYBottom + g.height)
        return CGRect(x: localX, y: localYTop, width: g.width, height: g.height)
    }
}
