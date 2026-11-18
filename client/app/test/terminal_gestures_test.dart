// 移动终端手势纯逻辑回归（PRD F3.2）：长按拖动方向键追踪器（三档速度/换向滞回）
// + TerminalPrefs 字号夹取与键序归一化（不触 FFI 的纯函数部分）。

import 'package:eterm/ui/terminal_gestures.dart';
import 'package:flutter_test/flutter_test.dart';

const _us = 1000; // 1ms 的微秒数

void main() {
  group('ArrowGestureTracker', () {
    test('启动死区：小于 deadZone 的位移不定向、不发键', () {
      final t = ArrowGestureTracker(deadZone: 12);
      expect(t.update(const Offset(5, 0), 0), isEmpty, reason: '首样本只记基线');
      expect(t.update(const Offset(10, 0), 100 * _us), isEmpty);
      expect(t.hasDirection, isFalse, reason: '5px < 12px 死区');
    });

    test('定向后沿轴发送：累计距离达到键间距才发键', () {
      final t = ArrowGestureTracker(deadZone: 12);
      expect(t.update(const Offset(0, 0), 0), isEmpty, reason: '基线');
      // 30px 右移（dt=1ms → 快速档键距 6；(30-12)=18px → 3 键）
      expect(t.update(const Offset(30, 0), 1 * _us), [
        ArrowDir.right,
        ArrowDir.right,
        ArrowDir.right,
      ]);
      // 慢速拖动（60px/150ms=0.4px/ms，键距 42px）→ 1 键
      expect(t.update(const Offset(90, 0), 151 * _us), [ArrowDir.right]);
    });

    test('三档速度键距：慢 42 / 中 15 / 快 6（px/键）', () {
      // 按恒速连续小帧拖动（贴近真实长按拖动的 move 采样），累计发键数应
      // 与"总距离 / 该档键距"一致。
      int total(double dxPerFrame, int dtUsPerFrame, int frames) {
        final t = ArrowGestureTracker(deadZone: 0);
        t.update(const Offset(0, 0), 0);
        var n = 0;
        for (var i = 1; i <= frames; i++) {
          n += t.update(Offset(dxPerFrame * i, 0), dtUsPerFrame * i).length;
        }
        return n;
      }

      // 慢 0.4px/ms：21 帧 × 4px = 84px / 42px = 2 键
      expect(total(4, 10000, 21), 2);
      // 中 1px/ms：9 帧 × 5px = 45px / 15px = 3 键
      expect(total(5, 5000, 9), 3);
      // 快 3px/ms：5 帧 × 6px = 30px / 6px = 5 键
      expect(total(6, 2000, 5), 5);
    });

    test('反向拖动：未超滞回不发键不换向；超过滞回翻转方向', () {
      final t = ArrowGestureTracker(
        deadZone: 0,
        switchHysteresis: 24,
        fastSpacing: 6,
      );
      expect(t.update(const Offset(0, 0), 0), isEmpty, reason: '基线');
      expect(t.update(const Offset(50, 0), 1 * _us), isNotEmpty,
          reason: '定向 right 并按快档发键');
      // 反向 20px（< 24 滞回）：不发键、方向不变
      expect(t.update(const Offset(30, 0), 2 * _us), isEmpty);
      // 再反向 11px：累计反向 31px 越过滞回 → 翻转为 left（换向帧不发键）
      expect(t.update(const Offset(19, 0), 3 * _us), isEmpty);
      // 继续左移 39px（快速档 6px 键距）→ 全部为 left
      expect(
          t.update(const Offset(-20, 0), 4 * _us).every((d) => d == ArrowDir.left),
          isTrue);
    });

    test('斜向：主轴定向（dx 主导 → 水平键）', () {
      final t = ArrowGestureTracker(deadZone: 12, fastSpacing: 6);
      expect(t.update(const Offset(0, 0), 0), isEmpty, reason: '基线');
      expect(t.update(const Offset(20, 5), 1 * _us), everyElement(ArrowDir.right));
      expect(t.update(const Offset(40, 7), 2 * _us), everyElement(ArrowDir.right));
    });

    test('向上拖动发送方向键 up', () {
      final t = ArrowGestureTracker(deadZone: 0, fastSpacing: 6);
      t.update(const Offset(0, -1), 0);
      expect(t.update(const Offset(0, -101), 33 * _us), everyElement(ArrowDir.up));
    });
  });

  group('TerminalPrefs 纯函数', () {
    test('clampFont：夹取到 [9, 24]', () {
      expect(TerminalPrefs.clampFont(13.5), 13.5);
      expect(TerminalPrefs.clampFont(5), TerminalPrefs.minFontSize);
      expect(TerminalPrefs.clampFont(30), TerminalPrefs.maxFontSize);
      expect(TerminalPrefs.clampFont(TerminalPrefs.defaultFontSize),
          TerminalPrefs.defaultFontSize);
    });

    test('normalizeExtraKeys：未知 id 丢弃、重复去重、缺失按默认序补齐', () {
      // 打乱 + 缺项 + 未知项 + 重复项
      final out = TerminalPrefs.normalizeExtraKeys(
          ['up', 'left', 'bogus', 'up', 'tab', 'down', 'ghost']);
      expect(out.first, 'up');
      expect(out, containsAll(['tab', 'down', 'left']));
      expect(out.where((id) => id == 'up'), hasLength(1));
      expect(out.contains('bogus') || out.contains('ghost'), isFalse);
      // 补齐后包含全部默认键（不多不少）
      expect(out.toSet(), TerminalPrefs.defaultExtraKeys.toSet());
      expect(out, hasLength(TerminalPrefs.defaultExtraKeys.length));
    });

    test('normalizeExtraKeys：空输入回退默认全序', () {
      expect(TerminalPrefs.normalizeExtraKeys([]),
          TerminalPrefs.defaultExtraKeys);
    });
  });
}
