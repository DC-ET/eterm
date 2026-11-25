// UI 共享小工具（评审 P1/P2 收敛重复实现）：
// - fmtLocalTime：ISO-UTC → 本地 "yyyy-MM-dd HH:mm:ss"（Logs/Known Hosts 同源）
// - fmtRelativeTime：访问时刻 → "刚刚/N 分钟前/…"（Hosts 最近访问）
// - dialogWidth：固定宽弹层夹到可用宽内（360dp 手机不溢出）
// - kMacTitleBarInset：macOS 自绘标题栏窗口里，推入页 AppBar 左侧让位交通灯

import 'package:material_ui/material_ui.dart';

/// UTC 时间串 → 本地 "yyyy-MM-dd HH:mm:ss"（解析失败原样返回）。
String fmtLocalTime(String ts) {
  try {
    return fmtLocalDateTime(DateTime.parse(ts));
  } catch (_) {
    return ts;
  }
}

/// 时间 → 本地 "yyyy-MM-dd HH:mm:ss"。
String fmtLocalDateTime(DateTime t) {
  final l = t.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  final ss = l.second.toString().padLeft(2, '0');
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} $hh:$mm:$ss';
}

/// 相对时间（Hosts「最近访问」副标题）。[now] 仅供测试注入。
/// 未来时间（时钟回拨）按"刚刚"处理，不出现负数。
String fmtRelativeTime(DateTime t, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(t);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 2) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final l = t.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
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
