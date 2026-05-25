import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - 剪映式编辑器：预览 + 时间线缩放段编辑 + 焦点编辑 + 首尾裁剪 + 摄像头图层 + 导出
//
// 数据真相是 EditorController.project；TimelineView 负责缩放段/裁剪的可视化与编辑，
// FocusOverlay 负责在预览上点选焦点、以及拖动/缩放摄像头图层。任何编辑都重建 videoComposition 即时预览。

// MARK: 时间线视图

protocol TimelineDelegate: AnyObject {
    func timelineDidSeek(to t: Double)
    func timelineDidSelect(_ id: UUID?)
    func timelineDidCommitEdits()
}

final class TimelineView: NSView {
    weak var delegate: TimelineDelegate?
    var duration: Double = 0
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var playhead: Double = 0
    var segments: [ZoomSegment] = []
    var selectedID: UUID?

    override var isFlipped: Bool { true }

    private let inset: CGFloat = 14
    private let rulerH: CGFloat = 18
    private let trackY: CGFloat = 38
    private let trackH: CGFloat = 58
    private let edgeGrab: CGFloat = 7
    private let trimGrab: CGFloat = 9

    private enum DragMode { case none, seek, moveSeg, resizeL, resizeR, trimS, trimE }
    private var dragMode: DragMode = .none
    private var dragSegIndex: Int = -1
    private var dragStartT: Double = 0
    private var origStart: Double = 0
    private var origEnd: Double = 0

    private func xFor(_ t: Double) -> CGFloat {
        guard duration > 0 else { return inset }
        return inset + CGFloat(t / duration) * (bounds.width - 2 * inset)
    }
    private func tFor(_ x: CGFloat) -> Double {
        guard duration > 0, bounds.width > 2 * inset else { return 0 }
        let p = Double((x - inset) / (bounds.width - 2 * inset))
        return min(max(p, 0), 1) * duration
    }

    // MARK: 绘制
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()

        // 刻度
        if duration > 0 {
            let step = niceStep(for: duration)
            NSColor(white: 0.32, alpha: 1).setStroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor(white: 0.55, alpha: 1),
            ]
            var t = 0.0
            while t <= duration + 0.001 {
                let x = xFor(t)
                let p = NSBezierPath()
                p.move(to: CGPoint(x: x, y: 0)); p.line(to: CGPoint(x: x, y: rulerH))
                p.lineWidth = 1; p.stroke()
                (timeLabel(t) as NSString).draw(at: CGPoint(x: x + 2, y: 2), withAttributes: attrs)
                t += step
            }
        }

        // 裁剪暗区
        NSColor(white: 0, alpha: 0.5).setFill()
        if trimStart > 0 {
            CGRect(x: xFor(0), y: rulerH, width: xFor(trimStart) - xFor(0), height: bounds.height - rulerH).fill()
        }
        let te = trimEnd > 0.001 ? trimEnd : duration
        if te < duration {
            CGRect(x: xFor(te), y: rulerH, width: xFor(duration) - xFor(te), height: bounds.height - rulerH).fill()
        }

        // 缩放段
        for seg in segments {
            let r = CGRect(x: xFor(seg.start), y: trackY,
                           width: max(4, xFor(seg.end) - xFor(seg.start)), height: trackH)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            let selected = seg.id == selectedID
            (selected ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.55)).setFill()
            path.fill()
            if selected {
                NSColor.systemYellow.setStroke(); path.lineWidth = 2; path.stroke()
            }
            let label = String(format: "%.1f×", seg.scale)
            (label as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 6), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ])
        }

        // 裁剪手柄
        NSColor.systemOrange.setFill()
        CGRect(x: xFor(trimStart) - 2, y: rulerH, width: 4, height: bounds.height - rulerH).fill()
        CGRect(x: xFor(te) - 2, y: rulerH, width: 4, height: bounds.height - rulerH).fill()

        // 播放头
        let px = xFor(playhead)
        NSColor.systemRed.setStroke()
        let ph = NSBezierPath()
        ph.move(to: CGPoint(x: px, y: 0)); ph.line(to: CGPoint(x: px, y: bounds.height))
        ph.lineWidth = 1.5; ph.stroke()
        NSColor.systemRed.setFill()
        let tri = NSBezierPath()
        tri.move(to: CGPoint(x: px - 5, y: 0)); tri.line(to: CGPoint(x: px + 5, y: 0))
        tri.line(to: CGPoint(x: px, y: 8)); tri.close(); tri.fill()
    }

    private func niceStep(for d: Double) -> Double {
        let targetTicks = 10.0
        let raw = d / targetTicks
        let steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return steps.first { $0 >= raw } ?? 300
    }
    private func timeLabel(_ t: Double) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 鼠标
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let x = pt.x
        let te = trimEnd > 0.001 ? trimEnd : duration

        if abs(x - xFor(trimStart)) <= trimGrab {
            dragMode = .trimS
        } else if abs(x - xFor(te)) <= trimGrab {
            dragMode = .trimE
        } else if let idx = segHit(at: pt) {
            let seg = segments[idx]
            dragSegIndex = idx
            origStart = seg.start; origEnd = seg.end
            dragStartT = tFor(x)
            selectedID = seg.id
            delegate?.timelineDidSelect(seg.id)
            if abs(x - xFor(seg.start)) <= edgeGrab { dragMode = .resizeL }
            else if abs(x - xFor(seg.end)) <= edgeGrab { dragMode = .resizeR }
            else { dragMode = .moveSeg }
        } else {
            // 空白：取消选中 + 跳转
            selectedID = nil
            delegate?.timelineDidSelect(nil)
            dragMode = .seek
            playhead = tFor(x)
            delegate?.timelineDidSeek(to: playhead)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let curT = tFor(pt.x)
        switch dragMode {
        case .seek:
            playhead = curT
            delegate?.timelineDidSeek(to: playhead)
        case .trimS:
            trimStart = min(max(0, curT), (trimEnd > 0.001 ? trimEnd : duration) - 0.2)
        case .trimE:
            trimEnd = max(min(duration, curT), trimStart + 0.2)
        case .moveSeg where dragSegIndex >= 0:
            let len = origEnd - origStart
            let delta = curT - dragStartT
            var ns = origStart + delta
            ns = min(max(0, ns), duration - len)
            segments[dragSegIndex].start = ns
            segments[dragSegIndex].end = ns + len
        case .resizeL where dragSegIndex >= 0:
            let delta = curT - dragStartT
            segments[dragSegIndex].start = min(max(0, origStart + delta), segments[dragSegIndex].end - 0.3)
        case .resizeR where dragSegIndex >= 0:
            let delta = curT - dragStartT
            segments[dragSegIndex].end = max(min(duration, origEnd + delta), segments[dragSegIndex].start + 0.3)
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .moveSeg, .resizeL, .resizeR, .trimS, .trimE:
            delegate?.timelineDidCommitEdits()
        default:
            break
        }
        dragMode = .none
        dragSegIndex = -1
    }

    private func segHit(at pt: NSPoint) -> Int? {
        guard pt.y >= trackY, pt.y <= trackY + trackH else { return nil }
        // 倒序：优先命中后画的（视觉在上）
        for i in segments.indices.reversed() {
            let r = CGRect(x: xFor(segments[i].start), y: trackY,
                           width: max(4, xFor(segments[i].end) - xFor(segments[i].start)), height: trackH)
            if r.insetBy(dx: -edgeGrab, dy: 0).contains(pt) { return i }
        }
        return nil
    }
}

// MARK: 预览覆盖层（焦点点选 + 摄像头拖动/缩放；都不需要时穿透给播放控件）

final class FocusOverlay: NSView {
    weak var controller: EditorController?
    var focusPoint: CGPoint?      // 焦点准星（视图坐标）

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let c = controller, (c.hasCamera || c.hasSelectedSegment) else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { controller?.overlayMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.overlayMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.overlayMouseUp(event) }

    override func draw(_ dirtyRect: NSRect) {
        if let p = focusPoint {
            NSColor.systemYellow.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
            ring.lineWidth = 2; ring.stroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: p.x - 8, y: p.y)); cross.line(to: CGPoint(x: p.x + 8, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 8)); cross.line(to: CGPoint(x: p.x, y: p.y + 8))
            cross.lineWidth = 1.5; cross.stroke()
        }
    }
}

// MARK: 编辑器控制器

final class EditorController: NSObject, TimelineDelegate, NSWindowDelegate {
    private let window: NSWindow
    let playerView = AVPlayerView()
    private let overlay = FocusOverlay()
    private let timeline = TimelineView()
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let build: ZoomCompositor.BuildResult
    private let projectDir: URL
    private let renderSize: CGSize
    private var project: ZoomProject
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var onClose: (() -> Void)?

    // 缩放段 / 壁纸工具栏（行 1）
    private let toolbar = NSStackView()
    private let scaleSlider = NSSlider(value: 1.8, minValue: 1.1, maxValue: 3.0, target: nil, action: nil)
    private let scaleLabel = NSTextField(labelWithString: "倍数 —")
    private let bgCheck = NSButton(checkboxWithTitle: "壁纸背景+圆角", target: nil, action: nil)
    private let bgPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let contentSlider = NSSlider(value: 0.86, minValue: 0.6, maxValue: 1.0, target: nil, action: nil)
    private let exportButton = NSButton(title: "导出成片", target: nil, action: nil)
    private var isExporting = false

    // 摄像头工具栏（行 2，仅有摄像头层时显示）
    private let toolbar2 = NSStackView()
    private let camShapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let camSizeSlider = NSSlider(value: 0.2, minValue: 0.08, maxValue: 0.5, target: nil, action: nil)
    private let camBorderCheck = NSButton(checkboxWithTitle: "白边", target: nil, action: nil)
    private let camBrightSlider = NSSlider(value: 0, minValue: -0.3, maxValue: 0.3, target: nil, action: nil)
    private let camSatSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)

    // 摄像头拖拽
    private enum CamDrag { case none, move, resize }
    private var camDrag: CamDrag = .none
    private var camDragStartCenter = CGPoint.zero
    private var camDragStartMouse = CGPoint.zero
    private var camDragStartScale: Double = 0

    var hasCamera: Bool { project.hasCamera }
    var hasSelectedSegment: Bool { timeline.selectedID != nil }

    // MARK: 打开
    @discardableResult
    static func open(projectDir: URL, onClose: @escaping () -> Void) async -> EditorController? {
        guard var project = ZoomProject.load(from: projectDir) else {
            NSLog("[Editor] 找不到 project.json: \(projectDir.path)"); return nil
        }
        guard let build = try? await ZoomCompositor.buildComposition(projectDir: projectDir, project: project) else {
            NSLog("[Editor] 组合视频失败"); return nil
        }
        if project.duration <= 0 { project.duration = build.duration }
        if project.trimEnd <= 0.001 { project.trimEnd = project.duration }
        return await MainActor.run {
            EditorController(projectDir: projectDir, build: build, project: project, onClose: onClose)
        }
    }

    private init(projectDir: URL, build: ZoomCompositor.BuildResult,
                 project: ZoomProject, onClose: @escaping () -> Void) {
        self.projectDir = projectDir
        self.build = build
        self.project = project
        self.renderSize = build.renderSize
        self.onClose = onClose
        self.item = AVPlayerItem(asset: build.composition)
        self.player = AVPlayer(playerItem: item)

        let rect = NSRect(x: 0, y: 0, width: 1100, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "聚录 编辑器 — \(projectDir.lastPathComponent)"
        window.center()

        super.init()

        item.videoComposition = ZoomCompositor.makeVideoComposition(build: build, project: project)
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        overlay.controller = self

        timeline.delegate = self
        timeline.duration = project.duration
        timeline.trimStart = project.trimStart
        timeline.trimEnd = project.effectiveTrimEnd
        timeline.segments = project.segments

        buildToolbars()
        let content = window.contentView!
        content.addSubview(playerView)
        content.addSubview(overlay)
        content.addSubview(toolbar)
        content.addSubview(toolbar2)
        content.addSubview(timeline)
        toolbar2.isHidden = !project.hasCamera
        layoutViews()

        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self else { return }
                self.timeline.playhead = time.seconds
                self.timeline.needsDisplay = true
                self.updateFocusMarker()
        }
        // Delete / ⌦ 删除当前选中的缩放段（仅编辑器为当前窗口时）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.window.isKeyWindow else { return e }
            if (e.keyCode == 51 || e.keyCode == 117), self.timeline.selectedID != nil {
                self.deleteSegment()
                return nil
            }
            return e
        }
        refreshInspector()
    }

    // MARK: 工具栏
    private func buildToolbars() {
        for tb in [toolbar, toolbar2] {
            tb.orientation = .horizontal
            tb.spacing = 8
            tb.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
            tb.alignment = .centerY
        }

        // 行 1：缩放段 + 壁纸 + 导出
        let add = NSButton(title: "＋缩放段", target: self, action: #selector(addSegment))
        let del = NSButton(title: "删除段", target: self, action: #selector(deleteSegment))
        scaleSlider.target = self; scaleSlider.action = #selector(scaleChanged)
        scaleSlider.isContinuous = true
        scaleSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        bgCheck.target = self; bgCheck.action = #selector(bgToggled)
        bgCheck.state = project.background ? .on : .off
        bgPopup.target = self; bgPopup.action = #selector(bgStyleChanged)
        for p in ZoomCompositor.bgPresets { bgPopup.addItem(withTitle: p.name) }
        bgPopup.addItem(withTitle: "自选图片…")
        if !project.backgroundImagePath.isEmpty { bgPopup.selectItem(at: bgPopup.numberOfItems - 1) }
        else { bgPopup.selectItem(at: min(project.backgroundStyle, ZoomCompositor.bgPresets.count - 1)) }
        contentSlider.target = self; contentSlider.action = #selector(contentChanged)
        contentSlider.isContinuous = true
        contentSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        contentSlider.doubleValue = project.contentScale
        exportButton.target = self; exportButton.action = #selector(exportTapped)
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        toolbar.addArrangedSubview(add)
        toolbar.addArrangedSubview(del)
        toolbar.addArrangedSubview(scaleLabel)
        toolbar.addArrangedSubview(scaleSlider)
        toolbar.addArrangedSubview(bgCheck)
        toolbar.addArrangedSubview(bgPopup)
        toolbar.addArrangedSubview(contentSlider)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(exportButton)

        // 行 2：摄像头
        let camTitle = NSTextField(labelWithString: "摄像头")
        camTitle.font = NSFont.boldSystemFont(ofSize: 11)
        camShapePopup.target = self; camShapePopup.action = #selector(camShapeChanged)
        camShapePopup.addItems(withTitles: ["圆形", "圆角矩形"])
        camShapePopup.selectItem(at: project.camShape)
        camSizeSlider.target = self; camSizeSlider.action = #selector(camSizeChanged)
        camSizeSlider.isContinuous = true; camSizeSlider.doubleValue = project.camScale
        camSizeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        camBorderCheck.target = self; camBorderCheck.action = #selector(camBorderToggled)
        camBorderCheck.state = project.camBorder ? .on : .off
        for (s, sel, v) in [(camBrightSlider, #selector(camBrightChanged), project.camBrightness),
                            (camSatSlider, #selector(camSatChanged), project.camSaturation)] {
            s.target = self; s.action = sel; s.isContinuous = true; s.doubleValue = v
            s.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        toolbar2.addArrangedSubview(camTitle)
        toolbar2.addArrangedSubview(NSTextField(labelWithString: "形状")); toolbar2.addArrangedSubview(camShapePopup)
        toolbar2.addArrangedSubview(NSTextField(labelWithString: "大小")); toolbar2.addArrangedSubview(camSizeSlider)
        toolbar2.addArrangedSubview(camBorderCheck)
        toolbar2.addArrangedSubview(NSTextField(labelWithString: "亮度")); toolbar2.addArrangedSubview(camBrightSlider)
        toolbar2.addArrangedSubview(NSTextField(labelWithString: "饱和")); toolbar2.addArrangedSubview(camSatSlider)
        toolbar2.addArrangedSubview(NSView())
    }

    private func layoutViews() {
        guard let b = window.contentView?.bounds else { return }
        let tlH: CGFloat = 132
        let tbH: CGFloat = 40
        let tb2H: CGFloat = project.hasCamera ? 40 : 0
        timeline.frame = CGRect(x: 0, y: 0, width: b.width, height: tlH)
        toolbar.frame = CGRect(x: 0, y: tlH, width: b.width, height: tbH)
        toolbar2.frame = CGRect(x: 0, y: tlH + tbH, width: b.width, height: tb2H)
        let pvY = tlH + tbH + tb2H
        let pv = CGRect(x: 0, y: pvY, width: b.width, height: max(0, b.height - pvY))
        playerView.frame = pv
        overlay.frame = pv
    }
    func windowDidResize(_ notification: Notification) {
        layoutViews(); updateFocusMarker()
    }
    func windowWillClose(_ notification: Notification) {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        player.pause()
        onClose?()
    }

    // MARK: 重建预览
    private func rebuildComposition() {
        item.videoComposition = ZoomCompositor.makeVideoComposition(build: build, project: project)
        let t = player.currentTime()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func syncFromTimeline() {
        project.segments = timeline.segments
        project.trimStart = timeline.trimStart
        project.trimEnd = timeline.trimEnd
    }
    private func commit() {
        syncFromTimeline()
        rebuildComposition()
        project.save(to: projectDir)
        refreshInspector()
        updateFocusMarker()
    }

    // MARK: TimelineDelegate
    func timelineDidSeek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func timelineDidSelect(_ id: UUID?) { refreshInspector(); updateFocusMarker() }
    func timelineDidCommitEdits() { commit() }

    // MARK: 缩放段 / 壁纸 actions
    @objc private func addSegment() {
        let t = player.currentTime().seconds
        let seg = ZoomSegment(start: max(0, t - 0.1), end: min(project.duration, t + 1.5),
                              scale: scaleSlider.doubleValue, fx: 0.5, fy: 0.5)
        timeline.segments.append(seg)
        timeline.selectedID = seg.id
        timeline.needsDisplay = true
        commit()
    }
    @objc private func deleteSegment() {
        guard let id = timeline.selectedID else { return }
        timeline.segments.removeAll { $0.id == id }
        timeline.selectedID = nil
        timeline.needsDisplay = true
        commit()
    }
    @objc private func scaleChanged() {
        guard let id = timeline.selectedID,
              let idx = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        timeline.segments[idx].scale = scaleSlider.doubleValue
        timeline.needsDisplay = true
        scaleLabel.stringValue = String(format: "倍数 %.1f×", scaleSlider.doubleValue)
        commit()
    }
    @objc private func bgToggled() {
        project.background = (bgCheck.state == .on)
        rebuildComposition(); project.save(to: projectDir); refreshInspector()
    }
    @objc private func bgStyleChanged() {
        let idx = bgPopup.indexOfSelectedItem
        if idx >= ZoomCompositor.bgPresets.count {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.canChooseFiles = true; panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url { project.backgroundImagePath = url.path }
            else { bgPopup.selectItem(at: min(project.backgroundStyle, ZoomCompositor.bgPresets.count - 1)) }
        } else {
            project.backgroundImagePath = ""
            project.backgroundStyle = idx
        }
        rebuildComposition(); project.save(to: projectDir)
    }
    @objc private func contentChanged() {
        project.contentScale = contentSlider.doubleValue
        rebuildComposition()
    }

    // MARK: 摄像头 actions
    @objc private func camShapeChanged() {
        project.camShape = camShapePopup.indexOfSelectedItem
        rebuildComposition(); project.save(to: projectDir)
    }
    @objc private func camSizeChanged() {
        project.camScale = camSizeSlider.doubleValue
        rebuildComposition()
    }
    @objc private func camBorderToggled() {
        project.camBorder = (camBorderCheck.state == .on)
        rebuildComposition(); project.save(to: projectDir)
    }
    @objc private func camBrightChanged() { project.camBrightness = camBrightSlider.doubleValue; rebuildComposition() }
    @objc private func camSatChanged() { project.camSaturation = camSatSlider.doubleValue; rebuildComposition() }

    // MARK: 导出
    @objc private func exportTapped() {
        guard !isExporting else { return }
        syncFromTimeline(); project.save(to: projectDir)
        isExporting = true; exportButton.isEnabled = false
        let fmt = DateFormatter(); fmt.dateFormat = "HHmmss"
        let out = projectDir.appendingPathComponent("成片-\(fmt.string(from: Date())).mov")
        let snapshot = project
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ZoomCompositor.export(build: self.build, project: snapshot, to: out) { p in
                    self.exportButton.title = "导出中 \(Int(p * 100))%"
                }
                await MainActor.run {
                    self.isExporting = false; self.exportButton.isEnabled = true
                    self.exportButton.title = "导出成片"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false; self.exportButton.isEnabled = true
                    self.exportButton.title = "导出成片"
                    let a = NSAlert(); a.messageText = "导出失败"; a.informativeText = "\(error)"; a.runModal()
                }
            }
        }
    }

    // MARK: 预览覆盖层交互（摄像头拖拽 / 焦点点选）
    func overlayMouseDown(_ event: NSEvent) {
        let p = overlay.convert(event.locationInWindow, from: nil)
        // 点在摄像头上就直接拖动它（缩放用工具栏「大小」滑块）
        if let cr = cameraViewRect(), cr.contains(p) {
            camDrag = .move
            camDragStartCenter = CGPoint(x: project.camCenterX, y: project.camCenterY)
            camDragStartMouse = p
            return
        }
        camDrag = .none
        setFocus(at: p)
    }
    func overlayMouseDragged(_ event: NSEvent) {
        let p = overlay.convert(event.locationInWindow, from: nil)
        let vb = playerView.videoBounds
        guard vb.width > 1, vb.height > 1 else { return }
        switch camDrag {
        case .move:
            let dxn = Double((p.x - camDragStartMouse.x) / vb.width)
            let dyn = Double((p.y - camDragStartMouse.y) / vb.height)
            project.camCenterX = min(max(0, camDragStartCenter.x + dxn), 1)
            project.camCenterY = min(max(0, camDragStartCenter.y + dyn), 1)
            rebuildComposition()
        case .resize, .none:
            break
        }
    }
    func overlayMouseUp(_ event: NSEvent) {
        if camDrag != .none {
            project.save(to: projectDir); refreshInspector()
        }
        camDrag = .none
    }

    private func setFocus(at p: CGPoint) {
        guard let id = timeline.selectedID,
              let idx = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        let vb = playerView.videoBounds
        guard vb.width > 1, vb.height > 1 else { return }
        let nx = (p.x - vb.minX) / vb.width
        let ny = (p.y - vb.minY) / vb.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
        timeline.segments[idx].fx = Double(nx)
        timeline.segments[idx].fy = Double(ny)
        commit()
    }

    private func cameraViewRect() -> CGRect? {
        guard project.hasCamera else { return nil }
        let vb = playerView.videoBounds
        guard vb.width > 1, vb.height > 1 else { return nil }
        let dispW = CGFloat(project.camScale) * vb.width
        let dispH = project.camShape == 0 ? dispW : dispW * 9 / 16
        let cx = vb.minX + CGFloat(project.camCenterX) * vb.width
        let cy = vb.minY + CGFloat(project.camCenterY) * vb.height
        return CGRect(x: cx - dispW / 2, y: cy - dispH / 2, width: dispW, height: dispH)
    }

    private func updateFocusMarker() {
        guard let id = timeline.selectedID,
              let seg = timeline.segments.first(where: { $0.id == id }) else {
            overlay.focusPoint = nil; overlay.needsDisplay = true; return
        }
        let vb = playerView.videoBounds
        guard vb.width > 1 else { overlay.focusPoint = nil; overlay.needsDisplay = true; return }
        overlay.focusPoint = CGPoint(x: vb.minX + CGFloat(seg.fx) * vb.width,
                                     y: vb.minY + CGFloat(seg.fy) * vb.height)
        overlay.needsDisplay = true
    }

    private func refreshInspector() {
        let has = hasSelectedSegment
        scaleSlider.isEnabled = has
        if has, let seg = timeline.segments.first(where: { $0.id == timeline.selectedID }) {
            scaleSlider.doubleValue = seg.scale
            scaleLabel.stringValue = String(format: "倍数 %.1f×", seg.scale)
        } else {
            scaleLabel.stringValue = "倍数 —"
        }
        contentSlider.isEnabled = (bgCheck.state == .on)
        bgPopup.isEnabled = (bgCheck.state == .on)
    }
}
