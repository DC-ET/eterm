package dev.eterm.eterm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 终端连接保持前台服务（技术方案 M1：Android 壳三件套之一）。
 *
 * 有活跃终端标签时由 Dart 侧经 MethodChannel("eterm/fg") 启动；常驻低优先级
 * 通知，防止系统在应用退后台后冻结进程、掐断 SSH 数据面连接（架构铁律：
 * 客户端与目标服务器本地直连，断连即业务中断）。关闭最后一个终端标签时由
 * Dart 侧经 stopService 停止（后台合法且幂等，见 MainActivity 注释）。
 */
class TerminalForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY 重启（intent == null）：宿主进程已死、会话全灭，保活失去
        // 意义——立即退出，不恢复僵尸常驻通知（评审 BUG-4）
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // API 29+ 必须声明服务类型；dataSync 对应 Manifest 中的 foregroundServiceType
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "终端连接",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply { setShowBadge(false) }
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("eterm")
            .setContentText("终端连接保持中")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "terminal"
        const val NOTIFICATION_ID = 41
    }
}
