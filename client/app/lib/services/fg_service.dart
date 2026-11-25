// Android 前台服务（会话连接保持）：有活跃工作区标签（终端 / SFTP）时启动
// 常驻通知，防止应用退后台后进程被冻结、SSH 数据面被掐断（M1 三件套之一）。
// 其他平台为 no-op；MethodChannel 未注册（桌面/测试）时静默忽略。

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class FgService {
  FgService._();

  static const MethodChannel _channel = MethodChannel('eterm/fg');

  /// active = 有活跃工作区标签（TerminalWorkTab 或 SftpWorkTab）。
  static void setKeepAlive(bool active) {
    if (!Platform.isAndroid) return;
    try {
      _channel.invokeMethod<void>(active ? 'start' : 'stop');
    } on MissingPluginException {
      // 非 Android 或引擎未注册通道：忽略
    } on PlatformException {
      // 权限缺失/系统拒绝：保持静默（连接仍在前台使用时不受影响）
    }
  }
}
