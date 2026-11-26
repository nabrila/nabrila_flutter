import AVFoundation
import CoreGraphics
import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

/// Native side of the replay: compresses frames to JPEG while the app runs
/// and turns the kept frames into one H.264 video when a report is sent.
/// Flutter has no JPEG or video encoder of its own, and PNG frames are about
/// ten times heavier than a video of the same moments.
///
/// Nothing runs on the main thread: on recent Flutter versions it is also
/// the UI thread, so encoding there would make the app stutter.
public class NabrilaPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "com.nabrila.replay", qos: .utility)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    // Arguments (1.3 MB of pixels per frame) are decoded off the main
    // thread, which is also Flutter's UI thread.
    let channel = FlutterMethodChannel(
      name: "nabrila/replay", binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?())
    registrar.addMethodCallDelegate(NabrilaPlugin(), channel: channel)
    FlutterEventChannel(name: "nabrila/shake", binaryMessenger: messenger)
      .setStreamHandler(ShakeStream.shared)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    if call.method == "supported" { return reply(true) }
    if call.method == "storageDir" { return reply(Self.storageDir()) }
    if call.method == "deviceModel" { return reply(Self.deviceModel()) }
    if call.method == "debugShake" {
      // For integration tests on a Simulator with no window to shake: the
      // key window gets the same shake gesture iOS sends.
      DispatchQueue.main.async {
        let window = UIApplication.shared.connectedScenes
          .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
        window?.motionEnded(.motionShake, with: nil)
        result(window != nil)
      }
      return
    }
    if call.method == "beginBackground" {
      // Asks iOS for time to finish an upload if the tester leaves the app
      // right after tapping Send; without it the app is frozen in seconds
      // and the report waits for the next launch.
      DispatchQueue.main.async {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "nabrila-upload") {
          UIApplication.shared.endBackgroundTask(id)
        }
        result(id == .invalid ? nil : id.rawValue)
      }
      return
    }
    if call.method == "endBackground" {
      if let raw = call.arguments as? Int {
        DispatchQueue.main.async {
          UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
      }
      return reply(nil)
    }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: nil, details: nil))
      return
    }
    switch call.method {
    case "jpeg":
      // Already on the background task queue; a frame never waits behind
      // a video, which runs on its own queue.
      reply(Self.jpeg(args))
    case "video":
      queue.async { reply(Self.video(args)) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// "apple iphone14,2": the hardware identifier, matched by the remote
  /// replay switch. The Simulator reports the model it imitates.
  private static func deviceModel() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return "apple \(simulated)".lowercased()
    }
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return "apple \(machine)".lowercased()
  }

  /// Folder where sealed reports wait until the server confirms them:
  /// Application Support (never purged by the system, unlike Caches or
  /// tmp), excluded from iCloud backups.
  private static func storageDir() -> String? {
    guard
      var url = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    url.appendPathComponent("nabrila-outbox", isDirectory: true)
    do {
      // Readable after the first unlock since boot, so a launch in the
      // background (prewarming, a push) can still send what waits here.
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    } catch {
      return nil
    }
    return url.path
  }

  private static let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

  /// `{rgba, width, height, quality}` → JPEG bytes. The alpha is ignored:
  /// the frames are opaque screens.
  private static func jpeg(_ args: [String: Any]) -> Any? {
    guard let rgba = (args["rgba"] as? FlutterStandardTypedData)?.data,
      let width = args["width"] as? Int, let height = args["height"] as? Int,
      let quality = args["quality"] as? Int, rgba.count >= width * height * 4,
      let provider = CGDataProvider(data: rgba as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: rgb,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      return FlutterError(code: "jpeg_input", message: nil, details: nil)
    }
    let out = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        out, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      return FlutterError(code: "jpeg_dest", message: nil, details: nil)
    }
    let options = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary
    CGImageDestinationAddImage(dest, image, options)
    guard CGImageDestinationFinalize(dest) else {
      return FlutterError(code: "jpeg_encode", message: nil, details: nil)
    }
    return FlutterStandardTypedData(bytes: out as Data)
  }

  /// `{frames: [jpeg], times: [ms from the first frame], width, height,
  /// bitrate, quality}` → MP4 bytes, one H.264 sample per frame at its time.
  /// A constant quality is used where the encoder supports it (measured on
  /// a real 20-frame flow: 63 KB with sharp text, against 134 KB at the
  /// 40 kbps fallback; below that, text softens). iPhones usually take the
  /// bitrate path. The keyframe interval barely changes the size.
  private static func video(_ args: [String: Any]) -> Any? {
    guard let frames = args["frames"] as? [FlutterStandardTypedData],
      let times = args["times"] as? [Int], frames.count == times.count, !frames.isEmpty,
      let rawWidth = args["width"] as? Int, let rawHeight = args["height"] as? Int,
      let bitrate = args["bitrate"] as? Int, let quality = args["quality"] as? Double
    else {
      return FlutterError(code: "video_args", message: nil, details: nil)
    }
    // Sides that are multiples of 16: H.264 works in 16-pixel blocks and
    // other sides leave a colored edge in some players. The frame is
    // scaled to them (at most 15 pixels, under 2 %), not cropped.
    let width = max(16, rawWidth & ~15)
    let height = max(16, rawHeight & ~15)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nabrila-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
      return FlutterError(code: "video_writer", message: nil, details: nil)
    }
    var compression: [String: Any] = [
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalKey: 30,
      AVVideoAllowFrameReorderingKey: false,
      AVVideoExpectedSourceFrameRateKey: 1,
    ]
    if supportsQuality {
      compression[AVVideoQualityKey] = quality
    } else {
      compression[AVVideoAverageBitRateKey] = bitrate
    }
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: compression,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(input) else {
      return FlutterError(code: "video_input", message: nil, details: nil)
    }
    writer.add(input)
    guard writer.startWriting() else {
      return FlutterError(code: "video_start", message: writer.error?.localizedDescription, details: nil)
    }
    writer.startSession(atSourceTime: .zero)

    var last = -1
    for (index, frame) in frames.enumerated() {
      let ms = times[index]
      // Presentation times must strictly increase.
      if ms <= last { continue }
      guard let pool = adaptor.pixelBufferPool,
        let image = decode(frame.data),
        let buffer = draw(image, pool: pool, width: width, height: height)
      else { continue }
      var waited = 0
      while !input.isReadyForMoreMediaData && waited < 2000 {
        usleep(2000)
        waited += 2
      }
      if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(ms), timescale: 1000)) {
        break
      }
      last = ms
    }
    input.markAsFinished()
    // The last frame stays on screen for one more second.
    writer.endSession(atSourceTime: CMTime(value: Int64(max(last, 0) + 1000), timescale: 1000))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed, let data = try? Data(contentsOf: url) else {
      return FlutterError(
        code: "video_finish", message: writer.error?.localizedDescription, details: nil)
    }
    return FlutterStandardTypedData(bytes: data)
  }

  /// Whether this device's H.264 encoder takes a constant quality. Asked
  /// of VideoToolbox first: an unsupported key would make AVFoundation
  /// raise an exception Swift cannot catch.
  private static let supportsQuality: Bool = {
    var made: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: 320, height: 640, codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &made)
    guard status == noErr, let session = made else { return false }
    defer { VTCompressionSessionInvalidate(session) }
    var supported: CFDictionary?
    guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported) == noErr,
      let keys = supported as? [String: Any]
    else { return false }
    return keys[kVTCompressionPropertyKey_Quality as String] != nil
  }()

  private static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func draw(_ image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int)
    -> CVPixelBuffer?
  {
    var made: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
      let buffer = made
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: rgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
