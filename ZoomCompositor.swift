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

    static func makeVideoComposition(build: BuildResult, project: ZoomProject,
                                     renderSize: CGSize? = nil) -> AVMutableVideoComposition {
        let rs = renderSize ?? build.renderSize
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TwoLayerCompositor.self
        vc.renderSize = rs
        vc.frameDuration = CMTime(value: 1, timescale: 60)
        let inst = TwoLayerInstruction(
            timeRange: CMTimeRange(start: .zero,
                                   duration: CMTime(seconds: max(0.1, build.duration), preferredTimescale: 600)),
            project: project,
            screenTrackID: build.screenTrackID,
            cameraTrackID: build.cameraTrackID,
            renderSize: rs)
        vc.instructions = [inst]
        return vc
    }

    // MARK: 导出

    /// 导出参数：编码 + 画质档（决定码率与分辨率上限）。容器固定 .mp4、音频固定单条 AAC。
    struct ExportSettings {
        enum Quality: Int {
            case high = 0       // 源分辨率，高码率
            case standard = 1   // 最短边降到 1080p，中码率（推荐，适配抖音/微信）
            case small = 2      // 最短边降到 720p，低码率，文件最小

            var maxShortSide: Int {   // 0 = 不缩放
                switch self {
                case .high: return 0
                case .standard: return 1080
                case .small: return 720
                }
            }
            var bitsPerPixel: Double { // 码率 ≈ 输出像素数 × 系数（bit/s）
                switch self {
                case .high: return 3.0
                case .standard: return 2.4
                case .small: return 2.0
                }
            }
        }

        var quality: Quality = .standard
        var useH264: Bool = true   // true=H.264（兼容优先）；false=HEVC（同画质更小，兼容差）

        /// 输出分辨率：按最短边限制、保持比例、取偶数
        func outputSize(for native: CGSize) -> CGSize {
            func even(_ v: CGFloat) -> CGFloat { let i = max(2, Int(v.rounded())); return CGFloat(i - (i % 2)) }
            let cap = quality.maxShortSide
            let shorter = min(native.width, native.height)
            guard cap > 0, shorter > CGFloat(cap) else {
                return CGSize(width: even(native.width), height: even(native.height))
            }
            let s = CGFloat(cap) / shorter
            return CGSize(width: even(native.width * s), height: even(native.height * s))
        }

        func videoSettings(outputSize sz: CGSize) -> [String: Any] {
            let w = Int(sz.width), h = Int(sz.height)
            let codecFactor = useH264 ? 1.0 : 0.6
            let bitrate = max(1_000_000, Int(Double(w * h) * quality.bitsPerPixel * codecFactor))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 60,
            ]
            let codec: AVVideoCodecType
            if useH264 {
                codec = .h264
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            } else {
                codec = .hevc
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: compression,
            ]
        }
    }

    /// 用 AVAssetReader（视频走自定义合成 + 音频把所有音轨混成单条）→ AVAssetWriter 导出 .mp4。
    /// 单条 AAC 音轨解决「抖音/微信只读第一条音轨导致没声音」；可控编码/码率/分辨率解决文件过大。
    static func export(build: BuildResult, project: ZoomProject, settings: ExportSettings,
                       to outURL: URL, onProgress: ((Double) -> Void)? = nil) async throws {
        let asset = build.composition
        let outSize = settings.outputSize(for: build.renderSize)
        let vc = makeVideoComposition(build: build, project: project, renderSize: outSize)

        // 裁剪范围（reader.timeRange）；输出时间戳减去 offset 归零到 0
        let start = max(0, project.trimStart)
        let end = project.effectiveTrimEnd
        let useTrim = end > start + 0.05
        let fullDur = CMTime(seconds: max(0.1, build.duration), preferredTimescale: 600)
        let timeRange = useTrim
            ? CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                          end: CMTime(seconds: end, preferredTimescale: 600))
            : CMTimeRange(start: .zero, duration: fullDur)
        let offset = timeRange.start
        let totalDur = timeRange.duration.seconds

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let allTracks = asset.tracks
        let videoTracks: [AVAssetTrack] = allTracks.filter { $0.mediaType == .video }
        let audioTracks: [AVAssetTrack] = allTracks.filter { $0.mediaType == .audio }

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = vc
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw RenderError.exportFailed("无法读取视频帧") }
        reader.add(videoOut)

        // 把所有音轨（系统声音 + 麦克风）混成单条 PCM
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); audioOut = ao }
        }

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoSettings(outputSize: outSize))
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw RenderError.exportFailed("无法写入视频") }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192000,
            ])
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioIn = ai }
        }

        guard reader.startReading() else {
            throw RenderError.exportFailed(reader.error?.localizedDescription ?? "读取启动失败")
        }
        guard writer.startWriting() else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "写入启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        let videoQueue = DispatchQueue(label: "export.video")
        let audioQueue = DispatchQueue(label: "export.audio")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(input: videoIn, output: videoOut, queue: videoQueue, offset: offset,
                           reader: reader, isVideo: true, totalDur: totalDur, onProgress: onProgress)
            }
            if let ai = audioIn, let ao = audioOut {
                group.addTask {
                    await pump(input: ai, output: ao, queue: audioQueue, offset: offset,
                               reader: reader, isVideo: false, totalDur: totalDur, onProgress: nil)
                }
            }
        }

        if reader.status == .failed {
            throw RenderError.exportFailed(reader.error?.localizedDescription ?? "读取失败")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "写入失败")
        }
        DispatchQueue.main.async { onProgress?(1) }
    }

    /// 把一路 reader 输出的样本泵进对应 writer input（必要时把时间戳减 offset 归零）
    private static func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput,
                             queue: DispatchQueue, offset: CMTime, reader: AVAssetReader,
                             isVideo: Bool, totalDur: Double,
                             onProgress: ((Double) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            var lastPct = -1
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sb = output.copyNextSampleBuffer() else {
                        if !resumed { resumed = true; input.markAsFinished(); cont.resume() }
                        return
                    }
                    let buf = (offset == .zero) ? sb : (retime(sb, by: offset) ?? sb)
                    input.append(buf)
                    if isVideo, totalDur > 0 {
                        // 按整数百分比节流，避免每帧都派发主线程
                        let pct = Int(min(1.0, CMSampleBufferGetPresentationTimeStamp(buf).seconds / totalDur) * 100)
                        if pct != lastPct {
                            lastPct = pct
                            DispatchQueue.main.async { onProgress?(Double(pct) / 100) }
                        }
                    }
                }
            }
        }
    }

    /// 复制一份样本并把所有时间戳减去 offset（用于裁剪后把成片首帧归零到 0）
    private static func retime(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0,
                arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count,
                arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sb, sampleTimingEntryCount: count,
                sampleTimingArray: &timings, sampleBufferOut: &out) == noErr else { return nil }
        return out
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
        } else if abs(out.extent.width - rs.width) > 1 || abs(out.extent.height - rs.height) > 1 {
            // 导出分辨率与源不同（如降到 1080p/720p）：把缩放后的屏幕整体贴合目标尺寸
            let e = out.extent
            if e.width > 1, e.height > 1 {
                out = out.transformed(by: CGAffineTransform(scaleX: rs.width / e.width,
                                                            y: rs.height / e.height))
            }
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
