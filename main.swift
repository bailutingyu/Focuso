import Cocoa
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import UniformTypeIdentifiers

// MARK: - 圆形浮窗本体
final class BubbleWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// 固定比例录制时把浮窗限制在录制区域内（全局 Cocoa 坐标）；nil=不限制
    var clampRegion: CGRect?
    override func setFrameOrigin(_ point: NSPoint) {
        var p = point
        if let r = clampRegion {
            let f = frame
            p.x = min(max(p.x, r.minX), max(r.minX, r.maxX - f.width))
            p.y = min(max(p.y, r.minY), max(r.minY, r.maxY - f.height))
        }
        super.setFrameOrigin(p)
    }
}

// MARK: - 承载摄像头预览的圆形 view
final class BubbleContentView: NSView {
    /// 窗口比内圆大一圈，留这些 padding 给阴影显示
    static let shadowPadding: CGFloat = 18

    private let innerLayer = CALayer()                 // 圆形裁剪
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let ringLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 外层 layer：不裁剪，承载阴影（CPU/GPU 仅在尺寸变化时算一次 shadowPath）
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        // 内层 layer：圆形裁剪
        innerLayer.masksToBounds = true
        innerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(innerLayer)

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.contentsGravity = .resizeAspectFill
        innerLayer.addSublayer(previewLayer)

        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ringLayer.lineWidth = 3
        innerLayer.addSublayer(ringLayer)

        updateGeometry()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private func updateGeometry() {
        let pad = Self.shadowPadding
        let inner = bounds.insetBy(dx: pad, dy: pad)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        innerLayer.frame = inner
        innerLayer.cornerRadius = inner.width / 2
        innerLayer.contentsScale = scale

        previewLayer.frame = innerLayer.bounds
        previewLayer.contentsScale = scale

        let ringInset = ringLayer.lineWidth / 2
        let r = CGRect(x: ringInset, y: ringInset,
                       width: innerLayer.bounds.width - ringInset * 2,
                       height: innerLayer.bounds.height - ringInset * 2)
        ringLayer.path = CGPath(ellipseIn: r, transform: nil)
        ringLayer.frame = innerLayer.bounds
        ringLayer.contentsScale = scale

        // 关键：圆形 shadowPath，避免 CA 每帧从 alpha 推测阴影形状
        layer?.shadowPath = CGPath(ellipseIn: inner, transform: nil)
        layer?.contentsScale = scale

        CATransaction.commit()
    }

    func attach(session: AVCaptureSession, mirrored: Bool) {
        previewLayer.session = session
        applyMirror(mirrored)
    }

    func applyMirror(_ mirrored: Bool) {
        guard let conn = previewLayer.connection else { return }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirrored
        }
    }

    // 圆外（含 padding）穿透鼠标，让下面应用可点
    override func hitTest(_ point: NSPoint) -> NSView? {
        let pad = Self.shadowPadding
        let inner = bounds.insetBy(dx: pad, dy: pad)
        let dx = point.x - inner.midX
        let dy = point.y - inner.midY
        let r = inner.width / 2
        if dx*dx + dy*dy > r*r { return nil }
        return super.hitTest(point)
    }

    // 任意位置按下都拖窗
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // 滚轮缩放：以中心为锚点（用户感知尺寸 = 内圆尺寸）
    override func scrollWheel(with event: NSEvent) {
        guard let window = window else { return }
        let pad = Self.shadowPadding
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.6 : 6)
        let old = window.frame
        let next = max(120 + pad * 2, min(500 + pad * 2, old.width + delta))
        if abs(next - old.width) < 0.5 { return }
        let cx = old.midX, cy = old.midY
        let f = NSRect(x: cx - next/2, y: cy - next/2, width: next, height: next)
        window.setFrame(f, display: true)
    }

    // 右键直接弹菜单
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = self.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - 屏幕录制（ScreenCaptureKit + AVAssetWriter）
final class ScreenRecorder: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput,
                            AVCaptureAudioDataOutputSampleBufferDelegate,
                            AVCaptureFileOutputRecordingDelegate {
    enum RecordError: Error { case noDisplay, writerFailed(String), micDenied }

    private let videoQueue = DispatchQueue(label: "rec.video")
    private let audioQueue = DispatchQueue(label: "rec.audio")
    private let micQueue = DispatchQueue(label: "rec.mic")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let micSession = AVCaptureSession()
    private let micOutput = AVCaptureAudioDataOutput()
    private var sessionStarted = false

    private(set) var isRecording = false
    var captureSystemAudio = true
    var micDevice: AVCaptureDevice?  // nil 表示不录麦克风
    var micGainDB: Double = 12        // 麦克风软件增益（dB）；0=不放大
    var onStateChange: ((Bool) -> Void)?
    /// 录制结束、文件就绪时回调（URL + 这次录制期间的鼠标事件）
    var onFinish: ((URL, [MouseEvent]) -> Void)?
    /// 录完是否自动打开编辑器（由 AppDelegate 在 onFinish 里执行）
    var autoZoomEnabled = true
    /// 录制期间的全局鼠标记录器
    let mouseTracker = MouseTracker()
    private(set) var lastOutputURL: URL?
    // 摄像头独立录制（双图层）
    private var cameraOutput: AVCaptureMovieFileOutput?
    private weak var cameraSessionRef: AVCaptureSession?
    private var cameraFinishCont: CheckedContinuation<Void, Never>?
    private var screenStartClock: CFTimeInterval = 0
    private var camStartClock: CFTimeInterval = 0
    private(set) var lastCameraURL: URL?
    private(set) var lastCameraOffset: Double = 0
    private(set) var recordingDisplayID: CGDirectDisplayID?
    private(set) var recordingDisplayName: String?

    func start(displayID: CGDirectDisplayID?, displayName: String?,
               cameraSession: AVCaptureSession? = nil, cameraMirrored: Bool = true,
               excludeWindowIDs: [CGWindowID] = [], sourceRect: CGRect? = nil) async throws {
        guard !isRecording else { return }
        micFrameCount = 0
        micFramesAppended = 0

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let display: SCDisplay?
        if let id = displayID {
            display = content.displays.first { $0.displayID == id } ?? content.displays.first
        } else {
            display = content.displays.first
        }
        guard let display = display else { throw RecordError.noDisplay }
        recordingDisplayID = display.displayID
        recordingDisplayName = displayName

        // 排除摄像头浮窗 + 录制区域指示框，让屏幕层干净
        var excluded: [SCWindow] = []
        for wid in excludeWindowIDs {
            if let w = content.windows.first(where: { $0.windowID == wid }) { excluded.append(w) }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let cfg = SCStreamConfiguration()
        let matchedScale: CGFloat = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let sr = sourceRect {
            // 固定比例：只录屏幕的某个矩形区域
            cfg.sourceRect = sr
            cfg.width = max(2, Int(sr.width * matchedScale) / 2 * 2)
            cfg.height = max(2, Int(sr.height * matchedScale) / 2 * 2)
        } else {
            cfg.width = Int(CGFloat(display.width) * matchedScale)
            cfg.height = Int(CGFloat(display.height) * matchedScale)
        }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 6
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // 关键：明确声明 sRGB 色彩空间，避免编码端按 BT.601 误转导致泛白
        if #available(macOS 13.0, *) {
            cfg.colorSpaceName = CGColorSpace.sRGB
        }
        if #available(macOS 13.0, *), captureSystemAudio {
            cfg.capturesAudio = true
        }

        // 输出到工程文件夹: ~/Downloads/Focuso/录制-<yyyyMMdd-HHmmss>/screen.mov
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let projectDir = downloads
            .appendingPathComponent("Focuso")
            .appendingPathComponent("录制-\(fmt.string(from: Date()))")
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("screen.mov")
        try? FileManager.default.removeItem(at: url)

        let w = try AVAssetWriter(outputURL: url, fileType: .mov)

        // HEVC + BT.709 完整色彩元数据 + 较高码率，匹配系统录屏画质
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: cfg.width,
            AVVideoHeightKey: cfg.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: cfg.width * cfg.height * 5,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        if w.canAdd(vIn) { w.add(vIn) }
        videoInput = vIn

        if #available(macOS 13.0, *), captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn) }
            audioInput = aIn
        }

        // 麦克风 audio track（独立于系统声音；QuickTime 播放时自动混音）
        if let mic = micDevice {
            try await ensureMicPermission()
            // 用 stereo 48k 兼容 DJI Mic、采访话筒等双声道设备
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192000,
            ]
            let mIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            mIn.expectsMediaDataInRealTime = true
            if w.canAdd(mIn) { w.add(mIn) }
            micInput = mIn
            try setupMicSession(device: mic)
        }

        guard w.startWriting() else {
            throw RecordError.writerFailed(w.error?.localizedDescription ?? "unknown")
        }
        writer = w
        lastOutputURL = url
        sessionStarted = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if #available(macOS 13.0, *), captureSystemAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        stream = s
        screenStartClock = CACurrentMediaTime()

        if micInput != nil {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.micSession.startRunning()
            }
        }

        // 摄像头独立录制成 camera.mov（第二图层）
        camStartClock = 0; lastCameraURL = nil; lastCameraOffset = 0
        if let camSession = cameraSession {
            let out = AVCaptureMovieFileOutput()
            camSession.beginConfiguration()
            if camSession.canAddOutput(out) { camSession.addOutput(out) }
            camSession.commitConfiguration()
            if let conn = out.connection(with: .video), conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = cameraMirrored
            }
            let camURL = projectDir.appendingPathComponent("camera.mov")
            try? FileManager.default.removeItem(at: camURL)
            cameraOutput = out
            cameraSessionRef = camSession
            lastCameraURL = camURL
            out.startRecording(to: camURL, recordingDelegate: self)
        }

        mouseTracker.start(displayID: display.displayID)
        isRecording = true
        await MainActor.run { self.onStateChange?(true) }
    }

    private func ensureMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { throw RecordError.micDenied }
        default:
            throw RecordError.micDenied
        }
    }

    private func setupMicSession(device: AVCaptureDevice) throws {
        micSession.beginConfiguration()
        micSession.inputs.forEach { micSession.removeInput($0) }
        micSession.outputs.forEach { micSession.removeOutput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        let canIn = micSession.canAddInput(input)
        if canIn { micSession.addInput(input) }
        let canOut = micSession.canAddOutput(micOutput)
        if canOut { micSession.addOutput(micOutput) }
        // 关键：强制把麦克风输出统一成 interleaved 16-bit PCM
        // 否则 DJI Mic 等 USB 设备会给出 non-interleaved Float32，AAC encoder 静默写空轨
        micOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        micOutput.setSampleBufferDelegate(self, queue: micQueue)
        micSession.commitConfiguration()

        NSLog("[Mic] setup device=\(device.localizedName) uid=\(device.uniqueID) canAddInput=\(canIn) canAddOutput=\(canOut)")
        NSLog("[Mic] inputs=\(micSession.inputs.count) outputs=\(micSession.outputs.count)")
        for (i, conn) in micOutput.connections.enumerated() {
            NSLog("[Mic] conn[\(i)] enabled=\(conn.isEnabled) active=\(conn.isActive) audioChannelCount=\(conn.audioChannels.count) inputPorts=\(conn.inputPorts.count)")
        }
        // 监听 runtime error
        NotificationCenter.default.removeObserver(self,
            name: AVCaptureSession.runtimeErrorNotification, object: micSession)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleMicRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: micSession)

        if !canIn || !canOut {
            throw RecordError.writerFailed("Mic session 无法添加 input/output（设备可能被占用或格式不兼容）")
        }
    }

    @objc private func handleMicRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        NSLog("[Mic] runtime error: \(err?.localizedDescription ?? "unknown") userInfo=\(note.userInfo ?? [:])")
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        let mouseEvents = mouseTracker.stop()
        if micSession.isRunning {
            micSession.stopRunning()
        }
        // 清掉 delegate 防止 stop 后 queue 里残留 sample 触发回调
        micOutput.setSampleBufferDelegate(nil, queue: nil)
        // 停摄像头录制并等待落盘
        if let out = cameraOutput {
            if out.isRecording {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    cameraFinishCont = cont
                    out.stopRecording()
                }
            }
            cameraSessionRef?.beginConfiguration()
            cameraSessionRef?.removeOutput(out)
            cameraSessionRef?.commitConfiguration()
            cameraOutput = nil
            lastCameraOffset = max(0, camStartClock - screenStartClock)
        }
        if let s = stream {
            try? await s.stopCapture()
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        if let w = writer {
            await w.finishWriting()
        }
        let url = lastOutputURL
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        sessionStarted = false
        recordingDisplayID = nil
        recordingDisplayName = nil
        await MainActor.run {
            self.onStateChange?(false)
            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                // 交给 AppDelegate：决定直接显示原片还是先渲染自动缩放成片
                self.onFinish?(url, mouseEvents)
            }
        }
    }

    // MARK: AVCaptureFileOutputRecordingDelegate（摄像头独立录制）
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        camStartClock = CACurrentMediaTime()
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let e = error { NSLog("[Camera] record finish error: \(e)") }
        cameraFinishCont?.resume()
        cameraFinishCont = nil
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard let w = writer, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // 只接受 complete 状态的帧
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first,
                  let raw = info[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw),
                  status == .complete else { return }

            if !sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                w.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        case .audio:
            if sessionStarted, audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        case .microphone:
            break  // 当前不录麦克风
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Recorder] stream stopped: \(error)")
        Task { await self.stop() }
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate（麦克风）
    private var micFrameCount = 0
    private var micFramesAppended = 0
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        micFrameCount += 1
        if micFrameCount == 1 {
            let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            NSLog("[Mic] FIRST sample: rate=\(asbd?.mSampleRate ?? -1) ch=\(asbd?.mChannelsPerFrame ?? 0) bits=\(asbd?.mBitsPerChannel ?? 0) flags=0x\(String(asbd?.mFormatFlags ?? 0, radix: 16))")
        }
        guard sampleBuffer.isValid else { return }
        guard sessionStarted else { return }
        guard let mic = micInput, mic.isReadyForMoreMediaData else { return }
        applyGain(toInt16SampleBuffer: sampleBuffer, gainDB: micGainDB)
        mic.append(sampleBuffer)
        micFramesAppended += 1
        if micFramesAppended == 1 || micFramesAppended % 500 == 0 {
            NSLog("[Mic] appended #\(micFramesAppended) writerStatus=\(writer?.status.rawValue ?? -1) writerErr=\(writer?.error?.localizedDescription ?? "-")")
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        NSLog("[Mic] dropped sample (slow consumer)")
    }

    /// 对 interleaved 16-bit PCM sampleBuffer 做软件增益（in-place，带限幅）
    private func applyGain(toInt16SampleBuffer sampleBuffer: CMSampleBuffer, gainDB: Double) {
        guard gainDB > 0.01 else { return }
        let gain = pow(10.0, gainDB / 20.0)   // dB -> linear
        // 用定点放大：gain << 15 避免每 sample 浮点乘
        let gainQ15 = Int32(gain * 32768.0)

        var listSize = 0
        var listPtr: UnsafeMutablePointer<AudioBufferList>?
        var bb: CMBlockBuffer?

        let status1 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status1 == noErr, listSize > 0 else { return }

        listPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { listPtr?.deallocate() }

        let status2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &bb
        )
        guard status2 == noErr, let ptr = listPtr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(ptr)
        for buffer in buffers {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard count > 0, let raw = buffer.mData else { continue }
            let samples = raw.bindMemory(to: Int16.self, capacity: count)
            for i in 0..<count {
                let v = (Int32(samples[i]) * gainQ15) >> 15
                samples[i] = Int16(max(-32768, min(32767, v)))
            }
        }
    }
}

// MARK: - 主控制器
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: BubbleWindow!
    private var content: BubbleContentView!
    private var statusItem: NSStatusItem!
    private let session = AVCaptureSession()
    private var currentDevice: AVCaptureDevice?
    private var mirrored = true
    private var cameraOff = false   // true=摄像头采集已停(常驻后台但不运行摄像头)
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let recorder = ScreenRecorder()
    private var recordingPulseTimer: Timer?
    private var pulseOn = false
    private var editor: EditorController?
    private var lastProjectDir: URL?
    private var recordAspectWH: CGFloat?          // nil=全屏；否则固定比例 宽/高
    private var regionSelector: RegionController?
    private var recordScreen: NSScreen?           // 固定比例录制到哪块屏；nil=主屏

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildStatusItem()
        refreshMenus()
        requestCameraAndStart()
        recorder.onStateChange = { [weak self] running in
            self?.applyRecordingState(running)
            self?.refreshMenus()
        }
        recorder.onFinish = { [weak self] url, events in
            self?.handleRecordingFinished(url: url, events: events)
        }
        recorder.micDevice = defaultMic()   // 默认用电脑自带麦克风（可在菜单选「关闭」不录）
        lastProjectDir = findLatestProjectDir()
        refreshMenus()
    }

    /// 扫描 ~/Downloads/Focuso/ 下的录制工程（含 project.json 或 screen.mov），按修改时间倒序
    private func recentProjectDirs(limit: Int = 10) -> [URL] {
        let fm = FileManager.default
        guard let base = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Focuso"),
              let items = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { dir in
                fm.fileExists(atPath: dir.appendingPathComponent("project.json").path)
                    || fm.fileExists(atPath: dir.appendingPathComponent("screen.mov").path)
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 最近一次录制工程（启动时用于决定默认目录）
    private func findLatestProjectDir() -> URL? { recentProjectDirs(limit: 1).first }

    // 浮窗关掉后 app 仍驻留在菜单栏，只有用户主动「退出」才结束
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 窗口
    private func buildWindow() {
        let bubbleSize: CGFloat = 220
        let pad = BubbleContentView.shadowPadding
        let winSize = bubbleSize + pad * 2
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - winSize - 24,
                             y: screen.minY + 24)
        let rect = NSRect(origin: origin, size: NSSize(width: winSize, height: winSize))

        window = BubbleWindow(contentRect: rect,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // 阴影改由 layer.shadowPath 渲染，省去窗口 alpha 阴影开销
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false

        content = BubbleContentView(frame: NSRect(origin: .zero, size: rect.size))
        window.contentView = content

        // 不抢焦点
        window.orderFrontRegardless()
    }

    // MARK: 摄像头
    private func requestCameraAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            start(device: defaultCamera())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok { self.start(device: self.defaultCamera()) }
                    else { self.cameraDenied() }
                }
            }
        default:
            cameraDenied()
        }
    }

    private func allCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .deskViewCamera, .continuityCamera])
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func defaultCamera() -> AVCaptureDevice? {
        return AVCaptureDevice.default(for: .video) ?? allCameras().first
    }

    private func start(device: AVCaptureDevice?) {
        guard let device else {
            NSLog("[Focuso] 没找到可用摄像头")
            return
        }
        currentDevice = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
            } catch {
                NSLog("[Focuso] 添加输入失败: \(error)")
            }
            // macOS 上修改 activeFormat 时 sessionPreset 会被自动调整为兼容值
            self.applyBestCameraFormat(device: device, targetFps: 60)
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }

            DispatchQueue.main.async {
                self.content.attach(session: self.session, mirrored: self.mirrored)
                self.refreshMenus()
            }
        }
    }

    /// 选一个支持高帧率的 format（限制在 1080p 以内避免占资源），锁 min/maxFrameDuration
    private func applyBestCameraFormat(device: AVCaptureDevice, targetFps: Double) {
        var pick: (AVCaptureDevice.Format, Double, Int32, Int32)?
        for fmt in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            if dims.width > 1920 || dims.height > 1080 { continue }  // 太大反而拖性能
            for range in fmt.videoSupportedFrameRateRanges {
                let cap = min(range.maxFrameRate, targetFps)
                // 帧率优先；同帧率下选分辨率更高的
                let better: Bool = {
                    guard let p = pick else { return true }
                    if cap > p.1 { return true }
                    if cap == p.1 && dims.width * dims.height > p.2 * p.3 { return true }
                    return false
                }()
                if better {
                    pick = (fmt, cap, dims.width, dims.height)
                }
            }
        }
        guard let (fmt, fps, w, h) = pick else {
            NSLog("[Camera] 没有合适的 format")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = fmt
            let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
            NSLog("[Camera] \(device.localizedName): \(w)x\(h) @ \(fps)fps")
        } catch {
            NSLog("[Camera] lock failed: \(error)")
        }
    }

    private func cameraDenied() {
        let alert = NSAlert()
        alert.messageText = "无法访问摄像头"
        alert.informativeText = "请打开 系统设置 → 隐私与安全性 → 摄像头，允许聚录 之后再试。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出")
        let r = alert.runModal()
        if r == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    // MARK: 菜单栏图标
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "video.circle",
                              accessibilityDescription: "聚录")
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = "聚录浮窗"
        }
    }

    // MARK: 菜单（菜单栏图标 + 浮窗右键 各持一份）
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 录屏区（一个动作；录哪块屏看「录制显示器」、什么比例看「录制比例」）
        if recorder.isRecording {
            let inProgress = NSMenuItem(
                title: "■ 停止录屏（\(recorder.recordingDisplayName ?? "屏幕")）",
                action: #selector(stopRecording(_:)),
                keyEquivalent: "r")
            inProgress.target = self
            menu.addItem(inProgress)
        } else {
            let start = NSMenuItem(title: "● 开始录屏",
                                   action: #selector(startRecording(_:)),
                                   keyEquivalent: "r")
            start.target = self
            menu.addItem(start)
        }

        let audioItem = NSMenuItem(title: "录制系统声音",
                                   action: #selector(toggleSystemAudio(_:)),
                                   keyEquivalent: "")
        audioItem.target = self
        audioItem.state = recorder.captureSystemAudio ? .on : .off
        audioItem.isEnabled = !recorder.isRecording
        menu.addItem(audioItem)

        // 录制比例（全屏 / 固定比例区域）
        let aspectRoot = NSMenuItem(title: "录制比例（\(aspectLabel())）", action: nil, keyEquivalent: "")
        let aspectMenu = NSMenu()
        aspectMenu.autoenablesItems = false
        let aspects: [(String, CGFloat?)] = [
            ("全屏", nil), ("16:9 横屏", 16.0 / 9.0), ("9:16 竖屏", 9.0 / 16.0),
            ("4:3", 4.0 / 3.0), ("3:4", 3.0 / 4.0)]
        for (label, wh) in aspects {
            let it = NSMenuItem(title: label, action: #selector(selectAspect(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = wh.map { NSNumber(value: Double($0)) } ?? NSNull()
            it.state = aspectMatches(wh) ? .on : .off
            it.isEnabled = !recorder.isRecording
            aspectMenu.addItem(it)
        }
        aspectRoot.submenu = aspectMenu
        aspectRoot.isEnabled = !recorder.isRecording
        menu.addItem(aspectRoot)

        // 多屏时：选录制到哪块显示器（区域框会显示在该屏）
        if NSScreen.screens.count > 1 {
            let scrRoot = NSMenuItem(title: "录制显示器（\((recordScreen ?? NSScreen.main)?.localizedName ?? "主屏")）", action: nil, keyEquivalent: "")
            let scrMenu = NSMenu(); scrMenu.autoenablesItems = false
            let mainID = (NSScreen.main?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let cur = recordScreen ?? NSScreen.main
            for (idx, s) in NSScreen.screens.enumerated() {
                let id = (s.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                let it = NSMenuItem(title: screenLabel(s, index: idx, isMain: id == mainID),
                                    action: #selector(selectRecordScreen(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = s
                it.state = (s == cur) ? .on : .off
                it.isEnabled = !recorder.isRecording
                scrMenu.addItem(it)
            }
            scrRoot.submenu = scrMenu
            scrRoot.isEnabled = !recorder.isRecording
            menu.addItem(scrRoot)
        }

        // —— 录制后编辑器 ——
        let autoItem = NSMenuItem(title: "录完自动打开编辑器",
                                  action: #selector(toggleAutoOpenEditor(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = recorder.autoZoomEnabled ? .on : .off
        autoItem.isEnabled = !recorder.isRecording
        menu.addItem(autoItem)

        // 打开录制工程：最近列表 + 选择任意历史文件夹
        let openRoot = NSMenuItem(title: "打开录制工程…", action: nil, keyEquivalent: "e")
        let openMenu = NSMenu(); openMenu.autoenablesItems = false
        let recents = recentProjectDirs(limit: 10)
        if recents.isEmpty {
            let none = NSMenuItem(title: "（暂无录制）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            openMenu.addItem(none)
        } else {
            for dir in recents {
                let it = NSMenuItem(title: dir.lastPathComponent,
                                    action: #selector(openProjectAt(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = dir
                openMenu.addItem(it)
            }
        }
        openMenu.addItem(.separator())
        let browse = NSMenuItem(title: "选择文件夹…", action: #selector(browseProject(_:)), keyEquivalent: "")
        browse.target = self
        openMenu.addItem(browse)
        openRoot.submenu = openMenu
        menu.addItem(openRoot)

        // 麦克风子菜单
        let micRoot = NSMenuItem(title: "麦克风", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let offItem = NSMenuItem(title: "关闭（不录麦克风）",
                                 action: #selector(selectMic(_:)),
                                 keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = NSNull()
        offItem.state = (recorder.micDevice == nil) ? .on : .off
        offItem.isEnabled = !recorder.isRecording
        micMenu.addItem(offItem)
        micMenu.addItem(.separator())
        for mic in allMicrophones() {
            let it = NSMenuItem(title: mic.localizedName,
                                action: #selector(selectMic(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = mic
            it.state = (mic.uniqueID == recorder.micDevice?.uniqueID) ? .on : .off
            it.isEnabled = !recorder.isRecording
            micMenu.addItem(it)
        }
        micRoot.submenu = micMenu
        menu.addItem(micRoot)

        // 麦克风增益
        let gainRoot = NSMenuItem(title: "麦克风增益", action: nil, keyEquivalent: "")
        let gainMenu = NSMenu()
        let gainOptions: [(String, Double)] = [
            ("不放大 (0 dB)", 0),
            ("+6 dB（≈ 2×）", 6),
            ("+12 dB（≈ 4×）", 12),
            ("+18 dB（≈ 8×）", 18),
        ]
        for (label, db) in gainOptions {
            let it = NSMenuItem(title: label,
                                action: #selector(selectMicGain(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = db
            it.state = (abs(recorder.micGainDB - db) < 0.1) ? .on : .off
            it.isEnabled = !recorder.isRecording
            gainMenu.addItem(it)
        }
        gainRoot.submenu = gainMenu
        gainRoot.isEnabled = (recorder.micDevice != nil)
        menu.addItem(gainRoot)

        if let url = recorder.lastOutputURL {
            let reveal = NSMenuItem(title: "在 Finder 中显示上次录像",
                                    action: #selector(revealLast(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = url
            menu.addItem(reveal)
        }
        menu.addItem(.separator())

        // 真正开/关摄像头采集（关闭后指示灯熄灭、不占摄像头，app 仍常驻菜单栏）
        let camToggle = NSMenuItem(
            title: cameraOff ? "打开摄像头" : "关闭摄像头",
            action: #selector(toggleCamera(_:)), keyEquivalent: "")
        camToggle.target = self
        camToggle.isEnabled = !recorder.isRecording
        menu.addItem(camToggle)

        // 浮窗显隐（仅摄像头开启时有意义）：只藏窗口，摄像头继续运行
        if !cameraOff {
            let toggle = NSMenuItem(
                title: (window?.isVisible ?? true) ? "隐藏摄像头浮窗" : "显示摄像头浮窗",
                action: #selector(toggleWindow(_:)),
                keyEquivalent: "h")
            toggle.target = self
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        let cams = allCameras()
        if !cams.isEmpty {
            let header = NSMenuItem(title: "摄像头", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for cam in cams {
                let item = NSMenuItem(title: "  " + cam.localizedName,
                                      action: #selector(switchCamera(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = cam
                if cam.uniqueID == currentDevice?.uniqueID { item.state = .on }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let mirror = NSMenuItem(title: "镜像画面", action: #selector(toggleMirror(_:)), keyEquivalent: "m")
        mirror.target = self
        mirror.state = mirrored ? .on : .off
        menu.addItem(mirror)

        let sizes: [(String, CGFloat)] = [("小 (140)", 140), ("中 (220)", 220), ("大 (320)", 320)]
        let sizeMenu = NSMenu()
        for (title, v) in sizes {
            let it = NSMenuItem(title: title, action: #selector(setSize(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            sizeMenu.addItem(it)
        }
        let sizeRoot = NSMenuItem(title: "尺寸", action: nil, keyEquivalent: "")
        sizeRoot.submenu = sizeMenu
        menu.addItem(sizeRoot)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出聚录",
                              action: #selector(quitApp(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func refreshMenus() {
        content?.menu = makeMenu()
        statusItem?.menu = makeMenu()
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        refreshMenus()
    }

    @objc private func toggleCamera(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        cameraOff.toggle()
        if cameraOff {
            // 关闭：停掉采集（摄像头指示灯熄灭）+ 隐藏浮窗
            window.orderOut(nil)
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning { self.session.stopRunning() }
            }
        } else {
            // 打开：重新采集 + 显示浮窗
            if session.inputs.isEmpty {
                start(device: defaultCamera())
            } else {
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
            window.orderFrontRegardless()
        }
        refreshMenus()
    }

    @objc private func switchCamera(_ sender: NSMenuItem) {
        guard let dev = sender.representedObject as? AVCaptureDevice else { return }
        start(device: dev)
    }

    @objc private func toggleMirror(_ sender: NSMenuItem) {
        mirrored.toggle()
        content.applyMirror(mirrored)
        refreshMenus()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? CGFloat else { return }
        let target = v + BubbleContentView.shadowPadding * 2
        let old = window.frame
        let cx = old.midX, cy = old.midY
        window.setFrame(NSRect(x: cx - target/2, y: cy - target/2,
                               width: target, height: target),
                        display: true, animate: true)
    }

    @objc private func quitApp(_ sender: Any?) {
        if recorder.isRecording {
            Task {
                await recorder.stop()
                await MainActor.run { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: 录屏 actions
    @objc private func startRecording(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        let screen = recordScreen ?? NSScreen.main
        let sid = screenID(screen)
        let name = screenLabel(screen, index: 0, isMain: sid == screenID(NSScreen.main))
        // 浮窗可见 → 排除它、并把摄像头单独录成第二层；摄像头关闭则不录摄像头层
        let camSession: AVCaptureSession? = cameraOff ? nil : session
        let mir = mirrored
        var excludeIDs: [CGWindowID] = []
        if window.isVisible { excludeIDs.append(CGWindowID(window.windowNumber)) }
        // 固定比例：换算 sourceRect，区域框切到虚线录制指示（并排除它不录进去）
        var sourceRect: CGRect? = nil
        var recID = sid
        if recordAspectWH != nil, let rs = regionSelector {
            sourceRect = rs.sourceRect()
            recID = rs.displayID ?? sid
            rs.setRecordingMode(true)
            if let wid = rs.windowID { excludeIDs.append(wid) }
        }
        Task {
            do {
                try await recorder.start(displayID: recID, displayName: name,
                                         cameraSession: camSession, cameraMirrored: mir,
                                         excludeWindowIDs: excludeIDs, sourceRect: sourceRect)
            } catch {
                await MainActor.run { self.showRecordError(error) }
            }
        }
    }

    // MARK: 录制比例 / 区域
    private func screenID(_ s: NSScreen?) -> CGDirectDisplayID? {
        (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func aspectLabel() -> String {
        guard let wh = recordAspectWH else { return "全屏" }
        let map: [(CGFloat, String)] = [(16.0/9.0, "16:9"), (9.0/16.0, "9:16"), (4.0/3.0, "4:3"), (3.0/4.0, "3:4")]
        return map.first { abs($0.0 - wh) < 0.01 }?.1 ?? "固定比例"
    }
    private func aspectMatches(_ wh: CGFloat?) -> Bool {
        guard let wh = wh else { return recordAspectWH == nil }
        guard let cur = recordAspectWH else { return false }
        return abs(cur - wh) < 0.01
    }

    @objc private func selectAspect(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        if sender.representedObject is NSNull {
            recordAspectWH = nil
            regionSelector?.hide()
            window.clampRegion = nil
        } else if let n = sender.representedObject as? NSNumber {
            let wh = CGFloat(n.doubleValue)
            recordAspectWH = wh
            showRegionSelector(aspectWH: wh)
        }
        refreshMenus()
    }

    @objc private func selectRecordScreen(_ sender: NSMenuItem) {
        guard !recorder.isRecording, let s = sender.representedObject as? NSScreen else { return }
        recordScreen = s
        if let wh = recordAspectWH { showRegionSelector(aspectWH: wh) }   // 在新屏重新框选
        refreshMenus()
    }

    private func showRegionSelector(aspectWH: CGFloat) {
        if regionSelector == nil { regionSelector = RegionController() }
        regionSelector!.show(aspectWH: aspectWH, on: recordScreen ?? NSScreen.main) { [weak self] regionGlobal in
            self?.window.clampRegion = regionGlobal
            self?.constrainBubble(to: regionGlobal)
        }
        let r = regionSelector!.regionGlobal
        window.clampRegion = r
        constrainBubble(to: r)
    }

    private func constrainBubble(to region: CGRect) {
        guard window.isVisible, region.width > 1 else { return }
        let f = window.frame
        var o = f.origin
        o.x = min(max(o.x, region.minX), max(region.minX, region.maxX - f.width))
        o.y = min(max(o.y, region.minY), max(region.minY, region.maxY - f.height))
        window.setFrameOrigin(o)
    }

    @objc private func stopRecording(_ sender: Any?) {
        guard recorder.isRecording else { return }
        Task { await recorder.stop() }
    }

    private func displayPayload(for screen: NSScreen) -> [String: Any] {
        let id = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let name = screenLabel(screen, index: 0, isMain: true)
        return ["id": id as Any, "name": name]
    }

    private func screenLabel(_ screen: NSScreen?, index: Int, isMain: Bool) -> String {
        guard let screen = screen else { return "Display \(index + 1)" }
        var name = screen.localizedName
        if name.isEmpty { name = "Display \(index + 1)" }
        let w = Int(screen.frame.width * screen.backingScaleFactor)
        let h = Int(screen.frame.height * screen.backingScaleFactor)
        let tag = isMain ? " · 主" : ""
        return "\(name)\(tag) · \(w)×\(h)"
    }

    @objc private func toggleSystemAudio(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        recorder.captureSystemAudio.toggle()
        refreshMenus()
    }

    // MARK: 编辑器 actions
    @objc private func toggleAutoOpenEditor(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        recorder.autoZoomEnabled.toggle()
        refreshMenus()
    }

    @objc private func openProjectAt(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        openEditorEnsuringProject(projectDir: dir)
    }

    /// 选择任意历史录制文件夹（或它的 project.json / screen.mov）来编辑
    @objc private func browseProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json, UTType.movie]
        panel.message = "选择录制工程文件夹（含 screen.mov），或它的 project.json"
        if let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Focuso"),
           FileManager.default.fileExists(atPath: base.path) {
            panel.directoryURL = base
        }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // 选中的是文件就取其所在文件夹
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue { url = url.deletingLastPathComponent() }
        openEditorEnsuringProject(projectDir: url)
    }

    /// 打开编辑器前确保该文件夹有 project.json（没有就用 mouse.json + 视频自动补一份）
    private func openEditorEnsuringProject(projectDir: URL) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.ensureProjectJSON(in: projectDir)
            await MainActor.run {
                if ok {
                    self.lastProjectDir = projectDir
                    self.refreshMenus()
                    self.openEditor(projectDir: projectDir)
                } else {
                    let a = NSAlert()
                    a.messageText = "无法打开该工程"
                    a.informativeText = "未在所选文件夹中找到可编辑的录像（screen.mov）。"
                    a.runModal()
                }
            }
        }
    }

    /// 没有 project.json 时，按录像 + mouse.json 自动生成一份并落盘；返回是否成功
    private func ensureProjectJSON(in dir: URL) async -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: ZoomProject.projectFileURL(in: dir).path) { return true }
        // 找主屏录像
        let videoName: String? = {
            for cand in ["screen.mov", "original.mov"] {
                if fm.fileExists(atPath: dir.appendingPathComponent(cand).path) { return cand }
            }
            if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
                return items.first {
                    ($0.hasSuffix(".mov") || $0.hasSuffix(".mp4"))
                        && $0 != "camera.mov" && !$0.hasPrefix("成片")
                }
            }
            return nil
        }()
        guard let videoName else { return false }
        let asset = AVURLAsset(url: dir.appendingPathComponent(videoName))
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        var events: [MouseEvent] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("mouse.json")),
           let evs = try? JSONDecoder().decode([MouseEvent].self, from: data) {
            events = evs
        }
        var project = ZoomProject.generate(fromEvents: events, duration: dur, videoFile: videoName)
        if fm.fileExists(atPath: dir.appendingPathComponent("camera.mov").path) {
            project.cameraVideoFile = "camera.mov"
        }
        project.save(to: dir)
        return true
    }

    /// 录制结束：建工程（写 mouse.json + project.json）→ 按需自动打开编辑器
    private func handleRecordingFinished(url: URL, events: [MouseEvent]) {
        regionSelector?.hide()   // 录完隐藏区域框
        let dir = url.deletingLastPathComponent()
        lastProjectDir = dir
        // 摄像头第二层信息
        let camFile: String? = {
            guard let cu = recorder.lastCameraURL,
                  FileManager.default.fileExists(atPath: cu.path) else { return nil }
            return cu.lastPathComponent
        }()
        let camOffset = recorder.lastCameraOffset
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: dir.appendingPathComponent("mouse.json"))
        }
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            var project = ZoomProject.generate(fromEvents: events, duration: dur)
            if let cf = camFile {
                project.cameraVideoFile = cf
                project.cameraTimeOffset = camOffset
            }
            project.save(to: dir)
            await MainActor.run {
                guard let self else { return }
                self.refreshMenus()
                if self.recorder.autoZoomEnabled {
                    self.openEditor(projectDir: dir)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
    }

    private func openEditor(projectDir: URL) {
        // 编辑阶段：隐藏摄像头浮窗和区域框，避免悬浮在屏幕上干扰
        window.orderOut(nil)
        regionSelector?.hide()
        refreshMenus()
        Task { [weak self] in
            let ctrl = await EditorController.open(projectDir: projectDir) { [weak self] in
                guard let self else { return }
                self.editor = nil
                // 编辑器关闭后回到摄像头浮窗主界面（保证屏幕上有可见窗口，app 不会“看起来退出”）
                self.window.orderFrontRegardless()
                self.refreshMenus()
            }
            await MainActor.run { self?.editor = ctrl }
        }
    }

    @objc private func selectMicGain(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        if let db = sender.representedObject as? Double {
            recorder.micGainDB = db
            refreshMenus()
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard !recorder.isRecording else { return }
        if sender.representedObject is NSNull {
            recorder.micDevice = nil
        } else if let dev = sender.representedObject as? AVCaptureDevice {
            recorder.micDevice = dev
        }
        refreshMenus()
    }

    private func allMicrophones() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(macOS 14.0, *) {
            types.append(.microphone)
            types.append(.external)
        } else {
            // 旧 API（已 deprecated 但能用）
            return AVCaptureDevice.devices(for: .audio)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// 电脑自带麦克风（找不到就退回系统默认音频输入）
    private func defaultMic() -> AVCaptureDevice? {
        let mics = allMicrophones()
        return mics.first {
            $0.localizedName.contains("MacBook") || $0.localizedName.contains("Built-in")
                || $0.localizedName.contains("内建") || $0.localizedName.contains("内置")
        } ?? AVCaptureDevice.default(for: .audio) ?? mics.first
    }

    @objc private func revealLast(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL,
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func showRecordError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法开始录屏"
        let ns = error as NSError
        alert.informativeText = "\(ns.localizedDescription)\n\n如果是首次使用，请到 系统设置 → 隐私与安全性 → 屏幕录制 中允许聚录，然后退出并重新打开本应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 录制时的菜单栏红点闪烁
    private func applyRecordingState(_ running: Bool) {
        recordingPulseTimer?.invalidate()
        recordingPulseTimer = nil
        if running {
            pulseOn = true
            updateStatusIcon(recording: true, on: true)
            recordingPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulseOn.toggle()
                self.updateStatusIcon(recording: true, on: self.pulseOn)
            }
        } else {
            updateStatusIcon(recording: false, on: false)
        }
    }

    private func updateStatusIcon(recording: Bool, on: Bool) {
        guard let btn = statusItem?.button else { return }
        if recording {
            let name = on ? "record.circle.fill" : "record.circle"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "正在录屏")
            // 录制时不用模板，让它显示红色
            img?.isTemplate = false
            btn.image = img
            if let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed]) as NSImage.SymbolConfiguration? {
                btn.image = img?.withSymbolConfiguration(cfg)
            }
            btn.toolTip = "正在录屏 — 点击停止"
        } else {
            let img = NSImage(systemSymbolName: "video.circle", accessibilityDescription: "聚录")
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = "聚录浮窗"
        }
    }
}

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
app.run()
