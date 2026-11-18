// 终端移动端手势（PRD F3.2 / Termius 调研报告 §七）：
// - 长按拖动 → 方向键连续发送（拖动越快键距越密，三档速度），静止长按 → 粘贴菜单
// - 双指捏合 → 终端字号（kv 持久化；仅双指接管竞技场，单指滚动/选择不受影响）
// - 偏好（字号/键条顺序）经 Rust kv 库持久化（非敏感项）
// ArrowGestureTracker 为纯逻辑类（无 Flutter 依赖），flutter test 直接覆盖。

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:eterm/src/rust/api/local.dart' as local;

/// 方向键（长按拖动手势的输出）。
enum ArrowDir { up, down, left, right }

/// 长按拖动方向键追踪器（Termius 式：同向连续按键，速度决定键间距）。
///
/// 纯逻辑：[update] 传入样本点与微秒时间戳（测试可注入合成时钟），返回本次
/// 应发送的方向键序列。方向一旦确定沿轴投影；反向拖动超过滞回距离才换向，
/// 避免斜向抖动来回发键。
class ArrowGestureTracker {
  ArrowGestureTracker({
    this.deadZone = 12.0,
    this.switchHysteresis = 24.0,
    this.slowSpacing = 42.0,
    this.mediumSpacing = 15.0,
    this.fastSpacing = 6.0,
  });

  /// 启动死区（px）：越过才确定初始方向。
  final double deadZone;

  /// 换向滞回（px）：反向分量超过该距离才翻转方向。
  final double switchHysteresis;

  /// 三档速度的键间距（px/键）：慢 ≤0.5px/ms，中 ≤1.6px/ms，快其余。
  final double slowSpacing;
  final double mediumSpacing;
  final double fastSpacing;

  ArrowDir? _dir;
  double _accum = 0; // 沿当前方向的待发键距离
  double _reverse = 0; // 反向分量累积（换向用）
  Offset _last = Offset.zero;
  int? _lastMicros;

  bool get hasDirection => _dir != null;

  Offset _vec(ArrowDir d) => switch (d) {
        ArrowDir.up => const Offset(0, -1),
        ArrowDir.down => const Offset(0, 1),
        ArrowDir.left => const Offset(-1, 0),
        ArrowDir.right => const Offset(1, 0),
      };

  ArrowDir _opposite(ArrowDir d) => switch (d) {
        ArrowDir.up => ArrowDir.down,
        ArrowDir.down => ArrowDir.up,
        ArrowDir.left => ArrowDir.right,
        ArrowDir.right => ArrowDir.left,
      };

  /// 速度分档 → 键间距（拖动越快，键距越密）。
  double _spacing(double speedPxPerMs) => speedPxPerMs < 0.5
      ? slowSpacing
      : speedPxPerMs < 1.6
          ? mediumSpacing
          : fastSpacing;

  /// 累积一次移动样本；返回本次应发送的方向键（可为空列表）。
  List<ArrowDir> update(Offset p, int micros) {
    final out = <ArrowDir>[];
    if (_lastMicros == null) {
      _last = p;
      _lastMicros = micros;
      return out;
    }
    final dtMs = ((micros - _lastMicros!) / 1000).clamp(1.0, 1000.0);
    final delta = p - _last;
    _last = p;
    _lastMicros = micros;
    if (delta.distance < 1.0) return out;
    // 先定键距（本次速度档），累积上限相对键距（3 倍），否则慢速档被上限卡死
    final spacing = _spacing(delta.distance / dtMs);

    if (_dir == null) {
      // 首次定向：越过启动死区，按位移主轴定向
      if (delta.distance < deadZone) return out;
      final horizontal = delta.dx.abs() >= delta.dy.abs();
      _dir = horizontal
          ? (delta.dx < 0 ? ArrowDir.left : ArrowDir.right)
          : (delta.dy < 0 ? ArrowDir.up : ArrowDir.down);
      _reverse = 0;
      _accum = (delta.distance - deadZone).clamp(0.0, 3 * spacing);
    } else {
      // 沿当前方向的投影分量；反向累积超过滞回才换向
      final forward = delta.dx * _vec(_dir!).dx + delta.dy * _vec(_dir!).dy;
      if (forward < 0) {
        _reverse += -forward;
        if (_reverse >= switchHysteresis) {
          _dir = _opposite(_dir!);
          _reverse = 0;
          _accum = 0; // 换向后重计距离（反向超出滞回的余量丢弃，防误发键）
        }
        return out;
      }
      _reverse = 0;
      _accum = (_accum + forward).clamp(0.0, 3 * spacing);
    }

    while (_accum >= spacing) {
      _accum -= spacing;
      out.add(_dir!);
    }
    return out;
  }
}

/// 双指捏合识别器：第二根触屏手指落下时对本指针竞技场表态接受（外层先于内层
/// hit-test，第二指可靠归属本识别器）。
/// 边界如实说明（评审 BUG-2）：若第一指已被内层滚动以 eagerWinner 接管，竞技场
/// 不翻盘——该指针 reject 后立即退出跟踪（rejectGesture），缩放停止但不产生并行
/// 脏状态；纯双指捏合路径干净。仅触摸设备参与（鼠标/触控笔不触发缩放）。
class PinchRecognizer extends OneSequenceGestureRecognizer {
  PinchRecognizer({required super.debugOwner})
      : super(supportedDevices: {PointerDeviceKind.touch});

  GestureScaleStartCallback? onStart;
  GestureScaleUpdateCallback? onUpdate;
  GestureScaleEndCallback? onEnd;

  final Map<int, Offset> _pointers = {};
  bool _accepted = false;
  double? _initialSpan;

  double _span() {
    if (_pointers.length < 2) return 0;
    final it = _pointers.values.iterator..moveNext();
    final a = it.current;
    Offset b = a;
    while (it.moveNext()) {
      b = it.current;
    }
    return (a - b).distance;
  }

  Offset _focal() {
    if (_pointers.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p;
    }
    return sum / _pointers.length.toDouble();
  }

  /// 覆写 addAllowedPointer（而非 addPointer）：supportedDevices 的触摸过滤在
  /// 基类 addPointer 里生效，覆写后者会绕过过滤（评审 OBS-6）。
  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _pointers[event.pointer] = event.position;
    // 第二根手指落下：对本竞技场表态接受（内层未决手势随后被 cancel）
    if (_pointers.length == 2 && !_accepted) {
      _accepted = true;
      resolve(GestureDisposition.accepted);
      _initialSpan = _span();
      onStart?.call(ScaleStartDetails(focalPoint: _focal(), localFocalPoint: _focal()));
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.position;
      // 至少两个仍归属本识别器的指针才计算 span（败诉/抬起的指针已移除）
      if (_accepted && _pointers.length >= 2 && _initialSpan != null && _initialSpan! > 0) {
        onUpdate?.call(ScaleUpdateDetails(
          scale: _span() / _initialSpan!,
          focalPoint: _focal(),
          localFocalPoint: _focal(),
        ));
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      stopTrackingPointer(event.pointer);
      if (_accepted && _pointers.length < 2) {
        _accepted = false;
        onEnd?.call(ScaleEndDetails());
      }
    }
  }

  @override
  void rejectGesture(int pointer) {
    // 竞技场败诉（如第一指已被内层滚动接管）：立即退出跟踪，防 stale 指针
    // 参与 span/onUpdate（评审 BUG-2）
    if (_pointers.remove(pointer) != null) {
      stopTrackingPointer(pointer);
      if (_accepted && _pointers.length < 2) {
        _accepted = false;
        onEnd?.call(ScaleEndDetails());
      }
    }
  }

  @override
  String get debugDescription => 'pinch';

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

/// 终端本地偏好（字号 / 附加键条顺序）：经 Rust kv 库持久化（非敏感项）。
/// 全局单例通知：多开终端标签共享同一字号/键序。
class TerminalPrefs {
  TerminalPrefs._();

  static const _fontSizeKey = 'terminal.font_size';
  static const _extraKeysKey = 'terminal.extra_keys';

  /// 桌面默认字号。
  static const double desktopFontSize = 13.5;

  /// 触屏默认字号：手机屏密度高、物理宽度小，13.5 单屏可见列数太少
  /// （任务清单 #2），默认 11.5 让单屏信息量接近桌面 80 列习惯。
  static const double touchFontSize = 11.5;

  static const double minFontSize = 9.0;
  static const double maxFontSize = 24.0;

  /// 平台默认字号（桌面 13.5 / 触屏 11.5；测试主机是桌面 → 测试恒定）。
  static double get defaultFontSize =>
      _isTouchDevice ? touchFontSize : desktopFontSize;

  static final bool _isTouchDevice = () {
    try {
      return defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;
    } catch (_) {
      return false;
    }
  }();

  /// 附加键条默认键序（id → 行为见 terminal_tab.dart 的分发）。
  static const List<String> defaultExtraKeys = [
    'tab', 'ctrl', 'up', 'down', 'left', 'right', 'esc',
    'colon', 'paste', 'times', 'equals', 'minus', 'slash',
  ];

  static final ValueNotifier<double> fontSize =
      ValueNotifier<double>(defaultFontSize);
  static final ValueNotifier<List<String>> extraKeys =
      ValueNotifier<List<String>>(List.unmodifiable(defaultExtraKeys));
  static bool _loaded = false;

  /// 字号夹取（纯函数，测试覆盖）。
  static double clampFont(double v) => v.clamp(minFontSize, maxFontSize);

  /// 键序归一化（纯函数，测试覆盖）：丢弃未知 id、按默认序补齐缺失项。
  static List<String> normalizeExtraKeys(List<String> raw) {
    final known = defaultExtraKeys.toSet();
    final seen = <String>{};
    final out = <String>[];
    for (final id in raw) {
      if (known.contains(id) && seen.add(id)) out.add(id);
    }
    for (final id in defaultExtraKeys) {
      if (!seen.contains(id)) out.add(id);
    }
    return out;
  }

  /// 启动时加载（同步 kv 读，sqlite 单行，毫秒级）。
  static void load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = double.tryParse(local.kvGet(key: _fontSizeKey));
      if (f != null) fontSize.value = clampFont(f);
      final raw = local.kvGet(key: _extraKeysKey);
      if (raw.isNotEmpty) {
        final ids = (raw.split(',').map((s) => s.trim()).toList());
        extraKeys.value = List.unmodifiable(normalizeExtraKeys(ids));
      }
    } catch (_) {
      // kv 不可用（如测试无 FFI）：内存默认值继续
    }
  }

  /// 更新字号。persist=false 用于捏合过程（每帧更新）；落盘见 persistFontSize。
  static void setFontSize(double v, {bool persist = true}) {
    final clamped = clampFont(v);
    fontSize.value = clamped;
    if (persist) persistFontSize();
  }

  /// 字号一次性落盘（捏合 onEnd 调用；onUpdate 每帧同步 FFI 写 sqlite 跑 UI
  /// 线程是 AGENTS.md frb sync 陷阱，评审 BUG-3）。
  static void persistFontSize() {
    try {
      local.kvPut(key: _fontSizeKey, value: fontSize.value.toStringAsFixed(1));
    } catch (_) {}
  }

  static void setExtraKeys(List<String> keys) {
    final normalized = normalizeExtraKeys(keys);
    extraKeys.value = List.unmodifiable(normalized);
    try {
      local.kvPut(key: _extraKeysKey, value: normalized.join(','));
    } catch (_) {}
  }

  static void resetExtraKeys() => setExtraKeys(defaultExtraKeys);
}
