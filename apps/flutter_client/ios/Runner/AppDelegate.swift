import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let device = FlutterMethodChannel(
        name: "popcorn/device", binaryMessenger: controller.binaryMessenger)
      device.setMethodCallHandler { call, result in
        if call.method == "freeBytes" {
          // Space left for downloads on the disk holding a path (see FreeSpace).
          let args = call.arguments as? [String: Any]
          let path = args?["path"] as? String ?? NSHomeDirectory()
          let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          result(values?.volumeAvailableCapacityForImportantUsage)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
