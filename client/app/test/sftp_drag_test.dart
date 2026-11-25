// 双栏拖放：起拖判定，以及鼠标拖放 / 轻点不被误伤。
// 触控板/触摸纵移留给列表滚动。

import 'package:eterm/ui/sftp_drag.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('未满阈值不开始拖，点击仍可用', () {
    expect(
      sftpDragWantsTransfer(const Offset(3, 2), PointerDeviceKind.mouse),
      isNull,
    );
    expect(
      sftpDragWantsTransfer(const Offset(7, 0), PointerDeviceKind.touch),
      isNull,
    );
  });

  test('鼠标越过阈值后任意方向都拖文件', () {
    expect(
      sftpDragWantsTransfer(
        const Offset(kSftpDragSlop, 0),
        PointerDeviceKind.mouse,
      ),
      isTrue,
    );
    expect(
      sftpDragWantsTransfer(const Offset(1, 12), PointerDeviceKind.mouse),
      isTrue,
    );
  });

  test('触控板与触摸：横移（含 45°）拖，纵移交给滚动', () {
    expect(
      sftpDragWantsTransfer(const Offset(10, 3), PointerDeviceKind.trackpad),
      isTrue,
    );
    expect(
      sftpDragWantsTransfer(const Offset(6, 6), PointerDeviceKind.touch),
      isTrue,
      reason: '正好 45° 仍算拖到对侧',
    );
    expect(
      sftpDragWantsTransfer(const Offset(3, 10), PointerDeviceKind.touch),
      isFalse,
    );
    expect(
      sftpDragWantsTransfer(const Offset(2, 12), PointerDeviceKind.trackpad),
      isFalse,
    );
  });

  testWidgets('轻点与不足阈值的晃动仍然打开，不开始拖', (tester) async {
    var taps = 0;
    String? dropped;
    await tester.pumpWidget(
      MaterialApp(
        home: DragTarget<String>(
          onAcceptWithDetails: (d) => dropped = d.data,
          builder: (_, _, _) => SftpPanelDraggable<String>(
            data: 'a.txt',
            feedback: const Text('a.txt'),
            child: GestureDetector(
              onTap: () => taps++,
              child: const SizedBox(
                width: 120,
                height: 40,
                child: Text('a.txt'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('a.txt'));
    await tester.pump();
    expect(taps, 1);
    expect(dropped, isNull);

    final origin = tester.getCenter(find.text('a.txt'));
    final nudge = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await nudge.moveBy(const Offset(3, 1));
    await nudge.up();
    await tester.pump();
    expect(taps, 2, reason: '3px 抖动仍是点击');
    expect(dropped, isNull);
  });

  testWidgets('鼠标拖过阈值落到目标；触摸纵移不开始拖', (tester) async {
    final dropped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: DragTarget<String>(
                onAcceptWithDetails: (d) => dropped.add(d.data),
                builder: (_, _, _) => const SizedBox.expand(),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: SftpPanelDraggable<String>(
                data: 'a.txt',
                feedback: const Material(child: Text('a.txt')),
                child: const SizedBox(
                  width: 80,
                  height: 36,
                  child: Text('a.txt'),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final origin = tester.getCenter(find.text('a.txt'));
    final mouse = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(0, 40));
    await mouse.up();
    await tester.pump();
    expect(dropped, ['a.txt']);

    dropped.clear();
    final touch = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.touch,
    );
    await touch.moveBy(const Offset(0, 40));
    await touch.up();
    await tester.pump();
    expect(dropped, isEmpty, reason: '触摸纵移不开始拖');
  });

  // MultiDragGestureRecognizer 默认 allowedButtonsFilter 只接受主键：
  // 右键留给行菜单，不能顺手把文件拖起来。锁行为，防未来放开组合键回归。
  testWidgets('右键拖动不开始拖（右键菜单手势不被抢）', (tester) async {
    final dropped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: DragTarget<String>(
                onAcceptWithDetails: (d) => dropped.add(d.data),
                builder: (_, _, _) => const SizedBox.expand(),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: SftpPanelDraggable<String>(
                data: 'a.txt',
                feedback: const Material(child: Text('a.txt')),
                child: const SizedBox(
                  width: 80,
                  height: 36,
                  child: Text('a.txt'),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final origin = tester.getCenter(find.text('a.txt'));
    final right = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.moveBy(const Offset(0, 40));
    await right.up();
    await tester.pump();
    expect(dropped, isEmpty, reason: '右键只用于弹菜单，不能把文件拖起来');
  });
}
