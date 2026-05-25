import AVFoundation
import CoreImage
import AppKit

// MARK: - 双图层合成：屏幕层(缩放) + 摄像头层(独立定位/形状/美颜)
//
// 用 AVMutableComposition 把 screen.mov 与 camera.mov 放成两条 video track，
// 再用自定义 AVVideoCompositing 同时取两层的当前帧合成。预览与导出共用。

enum ZoomCompositor {

    enum RenderError: Error { case noVideoTrack, exportFailed(String) }

    struct BuildResult {
        let composition: AVMutableComposition
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID    // Invalid 表示无摄像头层
        let renderSize: CGSize
        let duration: Double
    }

    // MARK: 组合 composition（屏幕 + 音轨 + 摄像头）

    static func buildComposition(projectDir: URL, project: ZoomProject) async throws -> BuildResult {
        let comp = AVMutableComposition()

        let screenAsset = AVURLAsset(url: projectDir.appendingPathComponent(project.videoFile))
        guard let screenVT = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let screenDur = try await screenAsset.load(.duration)
        let natural = try await screenVT.load(.naturalSize)
        let pref = try await screenVT.load(.preferredTransform)
        let d = natural.applying(pref)
        let renderSize = CGSize(width: abs(d.width), height: abs(d.height))

        // 用 track 实际分配到的 ID（不能硬编码：插入音轨会先占用 ID）
        var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if let st = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try st.insertTimeRange(CMTimeRange(start: .zero, duration: screenDur), of: screenVT, at: .zero)
            screenTrackID = st.trackID
        }

        // 屏幕的音轨（系统声音 + 麦克风）
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        for at in audioTracks {
            if let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? a.insertTimeRange(CMTimeRange(start: .zero, duration: screenDur), of: at, at: .zero)
            }
        }

        // 摄像头层
        var cameraTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if project.hasCamera {
            let camAsset = AVURLAsset(url: projectDir.appendingPathComponent(project.cameraVideoFile))
            if let camVT = try? await camAsset.loadTracks(withMediaType: .video).first {
                let camDur = (try? await camAsset.load(.duration)) ?? screenDur
                if let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let offset = CMTime(seconds: max(0, project.cameraTimeOffset), preferredTimescale: 600)
                    try? ct.insertTimeRange(CMTimeRange(start: .zero, duration: camDur), of: camVT, at: offset)
                    cameraTrackID = ct.trackID
                }
            }
        }

        return BuildResult(composition: comp, screenTrackID: screenTrackID,
                           cameraTrackID: cameraTrackID, renderSize: renderSize,
                           duration: screenDur.seconds)
    }

    static func makeVideoComposition(build: BuildResult, project: ZoomProject) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TwoLayerCompositor.self
        vc.renderSize = build.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 60)
        let inst = TwoLayerInstruction(
            timeRange: CMTimeRange(start: .zero,
                                   duration: CMTime(seconds: max(0.1, build.duration), preferredTimescale: 600)),
            project: project,
            screenTrackID: build.screenTrackID,
            cameraTrackID: build.cameraTrackID,
            renderSize: build.renderSize)
        vc.instructions = [inst]
        return vc
    }

    // MARK: 导出

    static func export(build: BuildResult, project: ZoomProject,
                       to outURL: URL, onProgress: ((Double) -> Void)? = nil) async throws {
        let vc = makeVideoComposition(build: build, project: project)
        guard let export = AVAssetExportSession(asset: build.composition,
                                                presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw RenderError.exportFailed("无法创建 AVAssetExportSession")
        }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mov
        export.videoComposition = vc
        export.shouldOptimizeForNetworkUse = true

        let start = max(0, project.trimStart)
        let end = project.effectiveTrimEnd
        if end > start + 0.05 {
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
        }

        let progressTimer = Timer(timeInterval: 0.25, repeats: true) { _ in
            let p = Double(export.progress)
            DispatchQueue.main.async { onProgress?(p) }
        }
        RunLoop.main.add(progressTimer, forMode: .common)
        await export.export()
        progressTimer.invalidate()

        switch export.status {
        case .completed:
            DispatchQueue.main.async { onProgress?(1) }
        default:
            throw RenderError.exportFailed(export.error?.localizedDescription ?? "未知错误")
        }
    }

    // MARK: 壁纸预设

    static let bgPresets: [(name: String, c0: CIColor, c1: CIColor)] = [
        ("深蓝紫", CIColor(red: 0.10, green: 0.12, blue: 0.18), CIColor(red: 0.20, green: 0.16, blue: 0.30)),
        ("石墨灰", CIColor(red: 0.10, green: 0.10, blue: 0.11), CIColor(red: 0.20, green: 0.20, blue: 0.22)),
        ("暖阳",   CIColor(red: 0.96, green: 0.55, blue: 0.30), CIColor(red: 0.86, green: 0.28, blue: 0.42)),
        ("青碧",   CIColor(red: 0.06, green: 0.30, blue: 0.34), CIColor(red: 0.10, green: 0.50, blue: 0.45)),
        ("月白",   CIColor(red: 0.90, green: 0.91, blue: 0.94), CIColor(red: 0.74, green: 0.77, blue: 0.84)),
    ]
}

// MARK: - 自定义合成 instruction（携带渲染所需参数）

final class TwoLayerInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let project: ZoomProject
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let renderSize: CGSize

    init(timeRange: CMTimeRange, project: ZoomProject,
         screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, renderSize: CGSize) {
        self.timeRange = timeRange
        self.project = project
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderSize = renderSize
        var ids: [NSValue] = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

// MARK: - 自定义合成器

final class TwoLayerCompositor: NSObject, AVVideoCompositing {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    var sourcePixelBufferAttributes: [String: Any]? =
        [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_32BGRA]]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] =
        [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_32BGRA]]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let inst = request.videoCompositionInstruction as? TwoLayerInstruction,
                  let outBuf = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "TwoLayer", code: -1))
                return
            }
            let image = compose(request: request, inst: inst)
            ciContext.render(image, to: outBuf,
                             bounds: CGRect(origin: .zero, size: inst.renderSize),
                             colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: outBuf)
        }
    }

    // MARK: 合成
    private func compose(request: AVAsynchronousVideoCompositionRequest, inst: TwoLayerInstruction) -> CIImage {
        let time = request.compositionTime.seconds
        let rs = inst.renderSize
        let p = inst.project
        let fullRect = CGRect(origin: .zero, size: rs)

        // 屏幕层
        let screen: CIImage
        if let sb = request.sourceFrame(byTrackID: inst.screenTrackID) {
            screen = CIImage(cvPixelBuffer: sb)
        } else {
            screen = CIImage(color: .black).cropped(to: fullRect)
        }
        let extent = screen.extent
        let st = p.state(at: time)
        var out = applyZoom(screen.clampedToExtent(), extent: extent, state: st)

        // 壁纸背景
        if p.background {
            out = applyBackground(out, project: p, renderSize: rs)
        }

        // 摄像头层
        if inst.cameraTrackID != kCMPersistentTrackID_Invalid,
           let cb = request.sourceFrame(byTrackID: inst.cameraTrackID) {
            let cam = beautify(CIImage(cvPixelBuffer: cb), project: p)
            out = placeCamera(cam, project: p, renderSize: rs).composited(over: out)
        }

        return out.cropped(to: fullRect)
    }

    // MARK: 屏幕缩放
    private func applyZoom(_ image: CIImage, extent: CGRect, state st: ZoomState) -> CIImage {
        let W = extent.width, H = extent.height
        let scale = CGFloat(st.scale)
        guard scale > 1.0001 else { return image.cropped(to: extent) }
        let cx = CGFloat(st.cx) * W, cy = CGFloat(st.cy) * H
        var dx = W / 2 - cx * scale, dy = H / 2 - cy * scale
        dx = min(0, max(W - W * scale, dx)); dy = min(0, max(H - H * scale, dy))
        let m = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        return image.transformed(by: m).cropped(to: extent)
    }

    // MARK: 壁纸背景 + 内容缩进圆角
    private func applyBackground(_ screen: CIImage, project p: ZoomProject, renderSize rs: CGSize) -> CIImage {
        let w = rs.width * CGFloat(p.contentScale), h = rs.height * CGFloat(p.contentScale)
        let contentRect = CGRect(x: (rs.width - w) / 2, y: (rs.height - h) / 2, width: w, height: h)
        let e = screen.extent
        let fit = CGAffineTransform(scaleX: contentRect.width / e.width, y: contentRect.height / e.height)
            .concatenating(CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
        let content = screen.transformed(by: fit)
        let clear = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: rs))
        if let mask = roundedRectMask(size: rs, rect: contentRect,
                                      radius: CGFloat(p.cornerRadius) * rs.height / 1080.0) {
            let rounded = content.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
            return rounded.composited(over: makeBackground(size: rs, project: p))
        }
        return content.composited(over: makeBackground(size: rs, project: p))
    }

    // MARK: 摄像头定位 / 形状 / 描边
    private func placeCamera(_ cam: CIImage, project p: ZoomProject, renderSize rs: CGSize) -> CIImage {
        let ce = cam.extent
        guard ce.width > 1, ce.height > 1 else { return CIImage.empty() }
        let dispW = max(40, CGFloat(p.camScale) * rs.width)
        let cx = CGFloat(p.camCenterX) * rs.width
        let cy = CGFloat(p.camCenterY) * rs.height

        var shaped: CIImage
        var boxW: CGFloat, boxH: CGFloat
        let clearFull = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: rs))

        if p.camShape == 0 {
            // 圆形：取中心正方形
            let side = min(ce.width, ce.height)
            let crop = CGRect(x: ce.midX - side / 2, y: ce.midY - side / 2, width: side, height: side)
            let s = dispW / side
            boxW = dispW; boxH = dispW
            var c = cam.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
            c = c.transformed(by: CGAffineTransform(translationX: cx - dispW / 2, y: cy - dispW / 2))
            if let mask = circleMask(diameter: dispW, center: CGPoint(x: cx, y: cy), size: rs) {
                shaped = c.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clearFull, kCIInputMaskImageKey: mask])
            } else { shaped = c }
        } else {
            // 圆角矩形：保持原比例
            let s = dispW / ce.width
            boxW = dispW; boxH = ce.height * s
            var c = cam.transformed(by: CGAffineTransform(translationX: -ce.minX, y: -ce.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
            c = c.transformed(by: CGAffineTransform(translationX: cx - boxW / 2, y: cy - boxH / 2))
            let box = CGRect(x: cx - boxW / 2, y: cy - boxH / 2, width: boxW, height: boxH)
            let r = CGFloat(p.camCornerRadius) * rs.height / 1080.0
            if let mask = roundedRectMask(size: rs, rect: box, radius: r) {
                shaped = c.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clearFull, kCIInputMaskImageKey: mask])
            } else { shaped = c }
        }

        // 白色描边（在摄像头下垫一个略大的白色形状）
        if p.camBorder {
            let bw = max(2, dispW * 0.02)
            let box = CGRect(x: cx - boxW / 2 - bw, y: cy - boxH / 2 - bw,
                             width: boxW + 2 * bw, height: boxH + 2 * bw)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: CGRect(origin: .zero, size: rs))
            let mask: CIImage?
            if p.camShape == 0 {
                mask = circleMask(diameter: box.width, center: CGPoint(x: cx, y: cy), size: rs)
            } else {
                mask = roundedRectMask(size: rs, rect: box,
                                       radius: CGFloat(p.camCornerRadius) * rs.height / 1080.0 + bw)
            }
            if let mask = mask {
                let border = white.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clearFull, kCIInputMaskImageKey: mask])
                shaped = shaped.composited(over: border)
            }
        }
        return shaped
    }

    // MARK: 美颜
    private func beautify(_ img: CIImage, project p: ZoomProject) -> CIImage {
        var x = img
        if abs(p.camBrightness) > 0.001 || abs(p.camSaturation - 1) > 0.001 {
            x = x.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: p.camBrightness,
                kCIInputSaturationKey: p.camSaturation,
                kCIInputContrastKey: 1.0])
        }
        if p.camSmooth > 0.001 {
            let blurred = x.applyingFilter("CIGaussianBlur",
                                           parameters: [kCIInputRadiusKey: 6.0 * p.camSmooth]).cropped(to: x.extent)
            x = x.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": blurred,
                "inputTime": min(0.85, p.camSmooth)]).cropped(to: x.extent)
        }
        if p.camWhiten > 0.001 {
            x = x.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.12 * p.camWhiten,
                kCIInputSaturationKey: 1.0 - 0.1 * p.camWhiten,
                kCIInputContrastKey: 1.0])
        }
        return x
    }

    // MARK: 壁纸生成
    private func makeBackground(size: CGSize, project p: ZoomProject) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        if !p.backgroundImagePath.isEmpty,
           let img = CIImage(contentsOf: URL(fileURLWithPath: p.backgroundImagePath)) {
            let e = img.extent
            if e.width > 1, e.height > 1 {
                let s = max(size.width / e.width, size.height / e.height)
                let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                let se = scaled.extent
                let dx = (size.width - se.width) / 2 - se.minX
                let dy = (size.height - se.height) / 2 - se.minY
                return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: full)
            }
        }
        let preset = ZoomCompositor.bgPresets[min(max(p.backgroundStyle, 0), ZoomCompositor.bgPresets.count - 1)]
        let g = CIFilter(name: "CILinearGradient")!
        g.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        g.setValue(CIVector(x: size.width, y: size.height), forKey: "inputPoint1")
        g.setValue(preset.c0, forKey: "inputColor0")
        g.setValue(preset.c1, forKey: "inputColor1")
        return (g.outputImage ?? CIImage(color: preset.c0)).cropped(to: full)
    }

    // MARK: 遮罩
    private func circleMask(diameter: CGFloat, center: CGPoint, size: CGSize) -> CIImage? {
        let r = diameter / 2
        guard r > 1 else { return nil }
        let g = CIFilter(name: "CIRadialGradient")!
        g.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        g.setValue(Double(r * 0.99), forKey: "inputRadius0")
        g.setValue(Double(r), forKey: "inputRadius1")
        g.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        g.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
        return g.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func roundedRectMask(size: CGSize, rect: CGRect, radius: CGFloat) -> CIImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
