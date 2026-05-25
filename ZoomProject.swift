import Foundation

// MARK: - 可编辑、可持久化的缩放工程（编辑器与渲染共用的数据真相）
//
// 录完后从鼠标元数据自动生成一份初始工程，用户在编辑器里增删/拖动缩放段、
// 调倍数与焦点、裁剪首尾、开关壁纸背景，全部落到 project.json，可重新打开继续编。

struct ZoomState {
    var scale: Double   // 当前缩放倍数（1 = 原始）
    var cx: Double      // 焦点归一化 X，左下原点（与 CIImage 一致）
    var cy: Double      // 焦点归一化 Y
}

/// 单个缩放段：start..end 为含过渡的整段时间，内部 ease-in 放大、停留、ease-out 复原
struct ZoomSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double          // ease-in 开始
    var end: Double            // ease-out 结束
    var easeIn: Double = 0.45
    var easeOut: Double = 0.6
    var scale: Double = 1.8
    var fx: Double = 0.5       // 焦点归一化 X，左下原点
    var fy: Double = 0.5       // 焦点归一化 Y

    var inEnd: Double { start + easeIn }
    var outStart: Double { end - easeOut }
}

struct ZoomProject: Codable {
    var videoFile: String = "original.mov"   // 相对工程目录
    var duration: Double = 0                 // 视频总时长（秒）
    var trimStart: Double = 0                // 首尾裁剪
    var trimEnd: Double = 0                  // 0 表示到结尾（load 时会补成 duration）
    var background: Bool = false             // 壁纸背景 + 圆角
    var contentScale: Double = 0.86          // 背景模式下内容占比
    var cornerRadius: Double = 24            // 内容圆角（1080p 基准）
    var backgroundStyle: Int = 0             // 壁纸预设索引（见 ZoomCompositor.bgPresets）
    var backgroundImagePath: String = ""     // 非空则用自选图片当壁纸

    // —— 摄像头独立图层（双图层录制）——
    var cameraVideoFile: String = ""         // "camera.mov"；空=无独立摄像头层
    var cameraTimeOffset: Double = 0         // 摄像头相对屏幕的时间偏移（秒）
    var camCenterX: Double = 0.84            // 摄像头中心归一化 X（左下原点）
    var camCenterY: Double = 0.16            // 默认右下角
    var camScale: Double = 0.2               // 摄像头显示宽度占画面宽的比例
    var camShape: Int = 0                    // 0=圆形, 1=圆角矩形
    var camCornerRadius: Double = 16         // 圆角矩形圆角（1080p 基准）
    var camBorder: Bool = true               // 白色描边
    var camBrightness: Double = 0            // 美颜：亮度 -0.3..0.3
    var camSaturation: Double = 1.0          // 美颜：饱和度 0..2
    var camSmooth: Double = 0                // 美颜：磨皮 0..1
    var camWhiten: Double = 0                // 美颜：美白 0..1

    var hasCamera: Bool { !cameraVideoFile.isEmpty }

    var segments: [ZoomSegment] = []

    var effectiveTrimEnd: Double { trimEnd > 0.001 ? trimEnd : duration }

    // MARK: 任意时刻的缩放状态
    func state(at t: Double) -> ZoomState {
        // 命中包含 t 的段（重叠时取最先开始的）
        guard let seg = segments
            .sorted(by: { $0.start < $1.start })
            .first(where: { t >= $0.start && t <= $0.end }) else {
            return ZoomState(scale: 1, cx: 0.5, cy: 0.5)
        }
        let zp: Double
        if t < seg.inEnd {
            zp = Self.smooth((t - seg.start) / max(0.001, seg.easeIn))
        } else if t > seg.outStart {
            zp = 1 - Self.smooth((t - seg.outStart) / max(0.001, seg.easeOut))
        } else {
            zp = 1
        }
        let scale = 1 + (seg.scale - 1) * zp
        return ZoomState(scale: scale, cx: seg.fx, cy: seg.fy)
    }

    static func smooth(_ p: Double) -> Double {
        let x = min(max(p, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: 从鼠标事件自动生成初始工程

    struct GenConfig {
        var zoomScale = 1.8
        var easeIn = 0.45
        var easeOut = 0.6
        var leadIn = 0.12
        var hold = 1.1
        var clusterGap = 2.0
    }

    static func generate(fromEvents events: [MouseEvent],
                         duration: Double,
                         videoFile: String = "screen.mov",
                         cfg: GenConfig = GenConfig()) -> ZoomProject {
        var project = ZoomProject(videoFile: videoFile, duration: duration, trimEnd: duration)
        let clicks = events.filter { $0.kind == .leftDown || $0.kind == .rightDown }
        guard !clicks.isEmpty else { return project }

        // 1) 把时间相近的点击聚成簇
        var clusters: [[MouseEvent]] = []
        var cur: [MouseEvent] = []
        for c in clicks {
            if let last = cur.last, c.t - last.t > cfg.clusterGap {
                clusters.append(cur); cur = []
            }
            cur.append(c)
        }
        if !cur.isEmpty { clusters.append(cur) }

        // 2) 每簇生成一个缩放段，焦点取簇内点击的均值
        var segs: [ZoomSegment] = clusters.map { cluster in
            let first = cluster.first!.t
            let last = cluster.last!.t
            let fx = cluster.map { $0.x }.reduce(0, +) / Double(cluster.count)
            let fy = cluster.map { $0.y }.reduce(0, +) / Double(cluster.count)
            let start = max(0, first - cfg.leadIn)
            let end = min(duration, last + cfg.hold + cfg.easeOut)
            return ZoomSegment(start: start, end: end,
                               easeIn: cfg.easeIn, easeOut: cfg.easeOut,
                               scale: cfg.zoomScale, fx: fx, fy: fy)
        }

        // 3) 合并时间上重叠/紧挨的相邻段
        var merged: [ZoomSegment] = []
        for s in segs.sorted(by: { $0.start < $1.start }) {
            if var prev = merged.last, s.start <= prev.end {
                prev.end = max(prev.end, s.end)
                // 焦点取两者中点，避免合并后乱跳
                prev.fx = (prev.fx + s.fx) / 2
                prev.fy = (prev.fy + s.fy) / 2
                merged[merged.count - 1] = prev
            } else {
                merged.append(s)
            }
        }
        segs = merged

        project.segments = segs
        return project
    }

    // MARK: 读写

    static func projectFileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("project.json")
    }

    static func load(from dir: URL) -> ZoomProject? {
        let url = projectFileURL(in: dir)
        guard let data = try? Data(contentsOf: url),
              var p = try? JSONDecoder().decode(ZoomProject.self, from: data) else { return nil }
        if p.trimEnd < 0.001 { p.trimEnd = p.duration }
        return p
    }

    func save(to dir: URL) {
        let url = Self.projectFileURL(in: dir)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url)
        } catch {
            NSLog("[ZoomProject] save failed: \(error)")
        }
    }
}

// 容错解码：旧版 project.json 缺字段时退回默认值，避免打不开
extension ZoomProject {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoFile = try c.decodeIfPresent(String.self, forKey: .videoFile) ?? "original.mov"
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        contentScale = try c.decodeIfPresent(Double.self, forKey: .contentScale) ?? 0.86
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 24
        backgroundStyle = try c.decodeIfPresent(Int.self, forKey: .backgroundStyle) ?? 0
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath) ?? ""
        cameraVideoFile = try c.decodeIfPresent(String.self, forKey: .cameraVideoFile) ?? ""
        cameraTimeOffset = try c.decodeIfPresent(Double.self, forKey: .cameraTimeOffset) ?? 0
        camCenterX = try c.decodeIfPresent(Double.self, forKey: .camCenterX) ?? 0.84
        camCenterY = try c.decodeIfPresent(Double.self, forKey: .camCenterY) ?? 0.16
        camScale = try c.decodeIfPresent(Double.self, forKey: .camScale) ?? 0.2
        camShape = try c.decodeIfPresent(Int.self, forKey: .camShape) ?? 0
        camCornerRadius = try c.decodeIfPresent(Double.self, forKey: .camCornerRadius) ?? 16
        camBorder = try c.decodeIfPresent(Bool.self, forKey: .camBorder) ?? true
        camBrightness = try c.decodeIfPresent(Double.self, forKey: .camBrightness) ?? 0
        camSaturation = try c.decodeIfPresent(Double.self, forKey: .camSaturation) ?? 1.0
        camSmooth = try c.decodeIfPresent(Double.self, forKey: .camSmooth) ?? 0
        camWhiten = try c.decodeIfPresent(Double.self, forKey: .camWhiten) ?? 0
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? []
    }
}
