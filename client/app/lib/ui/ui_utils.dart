// UI 共享小工具（评审 P1/P2 收敛重复实现）：
// - fmtLocalTime：ISO-UTC → 本地 "yyyy-MM-dd HH:mm:ss"（Logs/Known Hosts 同源）
// - dialogWidth：固定宽弹层夹到可用宽内（360dp 手机不溢出）
// - kMacTitleBarInset：macOS 自绘标题栏窗口里，推入页 AppBar 左侧让位交通灯

import 'package:material_ui/material_ui.dart';

/// UTC 时间串 → 本地 "yyyy-MM-dd HH:mm:ss"（解析失败原样返回）。
String fmtLocalTime(String ts) {
  try {
    final t = DateTime.parse(ts).toLocal();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm:$ss';
  } catch (_) {
    return ts;
  }
}

/// 弹层内容宽度：期望值与「屏幕宽 - 48」取小，保证小屏不溢出。
double dialogWidth(double desired, BuildContext context) {
  final screenW = MediaQuery.sizeOf(context).width;
  return desired < screenW - 48 ? desired : screenW - 48;
}

/// macOS 隐藏标题栏窗口：交通灯占位宽（shell 自绘标题栏给内容行留 78px，
/// 推入页 AppBar 的 leading 用同量级让位；+48 再保 BackButton 完整命中区）。
const kMacTitleBarInset = 76.0;

/// 根导航 Key：更新链路在无页面上下文处（启动 SnackBar / 原生安装结果回传）
/// 触达 ScaffoldMessenger 与弹层（自动更新方案 §5.2/§6.2）。
final updateRootNavigatorKey = GlobalKey<NavigatorState>();
