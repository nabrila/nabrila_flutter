import Flutter
import ObjectiveC
import UIKit

/// Tells Dart when the phone is shaken, from the same shake gesture iOS
/// uses for "Undo": no motion sensor, no permission, and it also works in
/// the Simulator (Device ▸ Shake).
///
/// UIKit sends the gesture up the responder chain to the key window, so
/// `UIWindow.motionEnded` is swapped once for a version that calls the
/// original and then tells the listener. Nothing is sent while Dart is not
/// listening.
final class ShakeStream: NSObject, FlutterStreamHandler {
  static let shared = ShakeStream()
  fileprivate var sink: FlutterEventSink?
  private static var installed = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    Self.install()
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private typealias MotionEnded = @convention(c) (
    AnyObject, Selector, UIEvent.EventSubtype, UIEvent?
  ) -> Void

  /// Wraps `UIWindow.motionEnded(_:with:)` once. The previous implementation
  /// (UIWindow's own, or the one it inherits) is always called back with
  /// its own selector: UIResponder's version forwards that selector to the
  /// next responder, so calling it under a swizzled name would crash.
  private static func install() {
    if installed { return }
    installed = true
    let cls: AnyClass = UIWindow.self
    let selector = #selector(UIResponder.motionEnded(_:with:))
    guard let method = class_getInstanceMethod(cls, selector) else { return }
    let previous = unsafeBitCast(method_getImplementation(method), to: MotionEnded.self)
    let block: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = {
      window, motion, event in
      previous(window, selector, motion, event)
      if motion == .motionShake { ShakeStream.shared.sink?(nil) }
    }
    let wrapped = imp_implementationWithBlock(block)
    // UIWindow usually inherits motionEnded: adding it to UIWindow leaves
    // UIResponder (every view and controller) untouched.
    if !class_addMethod(cls, selector, wrapped, method_getTypeEncoding(method)) {
      method_setImplementation(method, wrapped)
    }
  }
}
