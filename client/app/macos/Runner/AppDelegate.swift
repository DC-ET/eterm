import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  // Sparkle 2 标准更新器（自动更新方案 §7.4）：沙盒应用走 Installer XPC
  // （Info.plist SUEnableInstallerLauncherService + entitlements mach-lookup 例外）。
  // 公钥就位才启动（评审 P3-6）：SUPublicEDKey 还是占位符时跳过，避免 Sparkle
  // 启动报错刷日志；手动入口经 FlutterError 明确报「未配置」。
  private var updaterController: SPUStandardUpdaterController?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    // 设置页「检查更新」手动入口（§7.5）：Dart → MethodChannel → Sparkle 标准界面接管
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    let channel = FlutterMethodChannel(
      name: "eterm/update", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "checkForUpdates" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let updater = self?.updaterController else {
        result(FlutterError(code: "not_configured",
                            message: "SUPublicEDKey 未配置（首次发布前需生成 Sparkle 密钥对）",
                            details: nil))
        return
      }
      updater.checkForUpdates(nil)
      result(nil)
    }

    let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    if publicKey.contains("NOT_SET") {
      NSLog("eterm: SUPublicEDKey 未配置，跳过 Sparkle 启动（见 docs/eterm-发布流程.md macOS 小节）")
    } else {
      updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
  }
}
