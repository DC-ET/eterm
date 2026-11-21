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

  // ⚠️ 本版本（Flutter 3.50）的 FlutterAppDelegate 未实现 applicationDidFinishLaunching:
  // selector（生命周期转发已重构进 FlutterAppLifecycleDelegate），在 override 里调
  // super 会抛 NSInvalidArgumentException unrecognized selector 且被 AppKit 吞掉，
  // 导致本方法体后半段（更新通道 + Sparkle 启动）静默不执行——实测踩坑，勿加回 super。
  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSLog("eterm: applicationDidFinishLaunching 进入")
    // 设置页「检查更新」手动入口（§7.5）：Dart → MethodChannel → Sparkle 标准界面接管
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      NSLog("eterm: mainFlutterWindow/contentViewController guard 未通过，跳过更新通道")
      return
    }
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
      if let updater = updaterController?.updater {
        NSLog("eterm: Sparkle updater 已创建 autoCheck=%d interval=%.0f",
              updater.automaticallyChecksForUpdates ? 1 : 0,
              updater.updateCheckInterval)
      } else {
        NSLog("eterm: SPUStandardUpdaterController 创建后 updater 为空")
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
