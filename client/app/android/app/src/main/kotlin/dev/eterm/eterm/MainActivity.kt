package dev.eterm.eterm

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        // 应用内更新安装状态回传 action（系统 PackageInstaller → 本应用 receiver，§6.2）
        private const val ACTION_INSTALL_STATUS = "dev.eterm.eterm.INSTALL_STATUS"
    }

    private var updateChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 终端连接保持前台服务的启停（Dart 侧 FgService；见 TerminalForegroundService）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eterm/fg")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        requestNotificationsIfNeeded()
                        startForegroundServiceCompat()
                        result.success(null)
                    }
                    "stop" -> {
                        // stopService：后台应用调用合法（startService 在后台会抛
                        // IllegalStateException 且 MethodChannel handler 内未捕获
                        // 会直接崩进程——评审 BUG-1）；服务未运行时为幂等 no-op。
                        stopService(Intent(this, TerminalForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 应用内更新安装通道（自动更新方案 §6.2）：installApk → session 安装
        updateChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eterm/update")
        updateChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.error("bad_args", "installApk 需要 path 参数", null)
                    } else {
                        installApk(path, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startForegroundServiceCompat() {
        val intent = Intent(this, TerminalForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /// Android 13+ 通知运行时权限：不请求则前台服务通知静默不可见（服务本身仍
    /// 运行），用户失去「连接保持中」的唯一可见信号（评审 BUG-6）。拒绝不阻断。
    private fun requestNotificationsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4201)
    }

    /// 应用内更新安装（自动更新方案 §6.2 时序）：
    /// 未授权未知来源 → 打开系统设置页并回 need_permission（Dart 出引导对话框）；
    /// 已授权 → PackageInstaller session 流入 APK → commit → 处理 PENDING_USER_ACTION
    /// 拉起系统安装确认界面 → 最终成功/失败回传 Dart。
    private fun installApk(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.success(mapOf("status" to "error", "message" to "安装包不存在"))
            return
        }
        // Android 8+ 安装未知来源授权（REQUEST_INSTALL_PACKAGES 的运行时闸）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Exception) {
                // 个别 ROM 没有该设置页：仍回 need_permission，Dart 侧提示用户手动前往设置
            }
            result.success(mapOf("status" to "need_permission"))
            return
        }

        // 79MB 拷贝不能跑在主线程（MethodChannel handler 默认主线程，ANR 风险，
        // 评审 P1-1）：session 流程放单线程执行器，完成后回主线程应答（Result 必须主线程调）。
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        java.util.concurrent.Executors.newSingleThreadExecutor().execute {
            val installer = packageManager.packageInstaller
            var session: PackageInstaller.Session? = null
            var receiver: BroadcastReceiver? = null
            var committed = false
            var status = "error"
            var message = ""
            try {
                val sessionId = installer.createSession(
                    PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                )
                val s = installer.openSession(sessionId)
                session = s
                // APK 字节直接流入 session（session 路径不需要 FileProvider/content URI，§6.1）
                val out = s.openWrite("eterm.apk", 0, file.length())
                file.inputStream().use { input ->
                    input.copyTo(out, 256 * 1024)
                    out.flush()
                }
                out.close()

                // 先挂 receiver 再 commit，避免竞态丢状态回传
                receiver = registerInstallStatusReceiver()
                // 状态 PendingIntent 必须 FLAG_MUTABLE：系统经 fill-in 写入 EXTRA_STATUS，
                // IMMUTABLE 会静默丢 extras → 永远误报失败（评审 P0-1；Android 12+ 强制的
                // 是「显式声明 mutability」，PackageInstaller 场景恰好要求 mutable）
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                val intent = Intent(ACTION_INSTALL_STATUS).setPackage(packageName)
                val sender = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                s.commit(sender.intentSender)
                committed = true
                status = "started"
            } catch (e: Exception) {
                message = e.message ?: "$e"
            } finally {
                // 失败路径：注销 receiver + abandon 残留 session（否则系统侧 session 占着
                // 分区空间到重启才清，评审 P2-3）；成功路径只需释放本地 fd
                if (!committed) {
                    receiver?.let {
                        try {
                            unregisterReceiver(it)
                        } catch (_: Exception) {}
                    }
                    try {
                        session?.abandon()
                    } catch (_: Exception) {}
                } else {
                    try {
                        session?.close()
                    } catch (_: Exception) {}
                }
            }
            mainHandler.post { result.success(mapOf("status" to status, "message" to message)) }
        }
    }

    /// session commit 后的系统状态回传 receiver。
    /// 时序（Android 13+ 标准，评审 P0-2）：先收到一条 STATUS_PENDING_USER_ACTION 广播，
    /// 其 EXTRA_INTENT 携带系统安装确认 Activity 的 intent，**必须由我们 startActivity 拉起**；
    /// 最终 STATUS_SUCCESS / STATUS_FAILURE* 才注销 receiver 并回传 Dart（成功 code=0）。
    private fun registerInstallStatusReceiver(): BroadcastReceiver {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val status = intent.getIntExtra(
                    PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE
                )
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    val userAction = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_INTENT) as? Intent
                    }
                    if (userAction != null) {
                        userAction.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(userAction)
                        } catch (_: Exception) {}
                    }
                    return
                }
                try {
                    context.unregisterReceiver(this)
                } catch (_: Exception) {}
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
                updateChannel?.invokeMethod(
                    "onInstallStatus",
                    mapOf("code" to status, "message" to message)
                )
            }
        }
        val filter = IntentFilter(ACTION_INSTALL_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        return receiver
    }
}
