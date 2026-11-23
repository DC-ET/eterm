// 桌面双栏 SFTP 的起拖手势。
// 默认 Draggable 的鼠标阈值是 1px，手一抖就把点击吃成拖；这里等到 [kSftpDragSlop]。

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// 起拖阈值（逻辑像素）。小于此值仍是点击：打开目录、点 ⋮ 菜单。
const double kSftpDragSlop = 8;

/// 位移未满 [kSftpDragSlop] 时返回 null。
///
/// 鼠标不参与列表的拖动滚动（桌面 [ScrollBehavior] 不含 mouse），越过阈值后
/// 任意方向都开始拖文件。触控板与触摸会和列表滚动抢手势：横移（含正好 45°）
/// 开始拖，纵移交给滚动。
bool? sftpDragWantsTransfer(Offset delta, PointerDeviceKind kind) {
  if (delta.distance < kSftpDragSlop) return null;
  if (kind == PointerDeviceKind.mouse) return true;
  return delta.dx.abs() >= delta.dy.abs();
}

/// 文件行拖到对侧面板。判定见 [sftpDragWantsTransfer]。
class SftpPanelDraggable<T extends Object> extends Draggable<T> {
  const SftpPanelDraggable({
    super.key,
    required super.child,
    required super.feedback,
    required super.data,
    super.childWhenDragging,
  }) : super(
         maxSimultaneousDrags: 1,
         dragAnchorStrategy: pointerDragAnchorStrategy,
       );

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _SftpDragGestureRecognizer(debugOwner: this)..onStart = onStart;
  }
}

class _SftpDragGestureRecognizer extends MultiDragGestureRecognizer {
  _SftpDragGestureRecognizer({required super.debugOwner});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _SftpDragPointerState(event.position, event.kind, gestureSettings);
  }

  @override
  String get debugDescription => 'sftp panel drag';
}

class _SftpDragPointerState extends MultiDragPointerState {
  _SftpDragPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  /// 竞技场里只有自己时（文件行没有 onTap，鼠标也不参与滚动），
  /// pointer down 结束就会被判胜。那时还没过阈值，不能立刻开始拖。
  bool _won = false;
  bool _started = false;
  GestureMultiDragStartCallback? _starter;

  @override
  void checkForResolutionAfterMove() {
    final wants = _wants;
    if (wants == null) return;
    if (!wants) {
      if (!_started) resolve(GestureDisposition.rejected);
      return;
    }
    if (_won) {
      _start();
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    _starter = starter;
    _won = true;
    _start();
  }

  @override
  void rejected() {
    _won = false;
    _starter = null;
    super.rejected();
  }

  bool? get _wants {
    final delta = pendingDelta;
    if (delta == null) return null;
    return sftpDragWantsTransfer(delta, kind);
  }

  void _start() {
    if (_started || !_won || _starter == null || _wants != true) return;
    _started = true;
    final starter = _starter!;
    _starter = null;
    starter(initialPosition);
  }
}
