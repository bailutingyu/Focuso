import Cocoa

// MARK: - 鼠标事件记录（录制期间全局监听，供后期自动缩放使用）
//
// 关键点：监听鼠标的「移动 / 点击」用 NSEvent 全局监听器即可，
// 不需要「辅助功能 / 输入监控」权限（只有监听键盘才需要）。
// 坐标统一存成「所录显示器的归一化坐标」，原点在左下角（与 CoreImage 一致），
// 这样后期渲染时直接拿来用，不用再翻转 Y。

struct MouseEvent: Codable {
    enum Kind: String, Codable { case move, leftDown, rightDown }
    let t: Double     // 相对录制起点的秒数
    let x: Double     // 归一化 0–1，左下角为原点，相对所录显示器
    let y: Double
    let kind: Kind
}

final class MouseTracker {
    private var monitors: [Any] = []
    private var startTime: CFTimeInterval = 0
    private var screenFrame: CGRect = .zero      // 所录显示器的全局 Cocoa frame（左下原点）
    private var lastMoveStamp: CFTimeInterval = 0
    private let moveThrottle: CFTimeInterval = 0.03   // 移动事件最高 ~33Hz，控制数据量

    private(set) var events: [MouseEvent] = []

    /// 录制开始时调用：清空旧数据、记录起点、按所录显示器锁定坐标系
    func start(displayID: CGDirectDisplayID?) {
        events.removeAll(keepingCapacity: true)
        startTime = CACurrentMediaTime()
        lastMoveStamp = 0
        screenFrame = Self.frame(for: displayID)

        let types: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .rightMouseDown,
        ]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] e in
            self?.record(e)
        }) {
            monitors.append(m)
        }
        NSLog("[Mouse] tracker started, screenFrame=\(screenFrame)")
    }

    /// 录制结束时调用：停止监听并返回完整事件序列
    @discardableResult
    func stop() -> [MouseEvent] {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        NSLog("[Mouse] tracker stopped, events=\(events.count)")
        return events
    }

    private func record(_ e: NSEvent) {
        guard screenFrame.width > 1, screenFrame.height > 1 else { return }
        let now = CACurrentMediaTime()

        let kind: MouseEvent.Kind
        switch e.type {
        case .leftMouseDown:  kind = .leftDown
        case .rightMouseDown: kind = .rightDown
        default:
            // 移动 / 拖拽：节流，避免几千条冗余点
            if now - lastMoveStamp < moveThrottle { return }
            lastMoveStamp = now
            kind = .move
        }

        // NSEvent.mouseLocation：全局 Cocoa 坐标（左下原点，多屏拼接）
        let loc = NSEvent.mouseLocation
        let nx = (loc.x - screenFrame.minX) / screenFrame.width
        let ny = (loc.y - screenFrame.minY) / screenFrame.height
        // 屏外的事件丢弃（留 5% 容差）
        guard nx >= -0.05, nx <= 1.05, ny >= -0.05, ny <= 1.05 else { return }

        let t = now - startTime
        events.append(MouseEvent(t: t,
                                 x: min(max(nx, 0), 1),
                                 y: min(max(ny, 0), 1),
                                 kind: kind))
    }

    /// 把事件序列写到旁车 JSON（与视频同目录同名 + .zoommeta.json），便于调试与未来的时间线编辑
    static func writeSidecar(_ events: [MouseEvent], for videoURL: URL) {
        let url = videoURL.deletingPathExtension().appendingPathExtension("zoommeta.json")
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: url)
            NSLog("[Mouse] sidecar written: \(url.lastPathComponent) (\(events.count) events)")
        } catch {
            NSLog("[Mouse] sidecar write failed: \(error)")
        }
    }

    /// 找到指定显示器对应的 NSScreen.frame（全局 Cocoa 坐标）
    static func frame(for displayID: CGDirectDisplayID?) -> CGRect {
        if let id = displayID {
            for s in NSScreen.screens {
                let sid = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                if sid == id { return s.frame }
            }
        }
        return NSScreen.main?.frame ?? .zero
    }
}
