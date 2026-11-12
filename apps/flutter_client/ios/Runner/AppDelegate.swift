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
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? NSHomeDirectory()
        if call.method == "freeBytes" {
          // Space left for downloads on the disk holding a path (see FreeSpace).
          let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          result(values?.volumeAvailableCapacityForImportantUsage)
        } else if call.method == "excludeFromBackup" {
          // Keeps downloaded torrents out of iCloud/iTunes backups (see TorrentPaths).
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          do {
            try url.setResourceValues(values)
            result(true)
          } catch {
            result(false)
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
