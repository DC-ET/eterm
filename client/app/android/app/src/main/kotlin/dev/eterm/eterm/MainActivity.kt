package dev.eterm.eterm

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

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
}
