// 自动更新纯函数回归（自动更新方案 §10）：isNewer / 元数据解析 / sha256 比对 / 节流。
// 纯函数、无网络、无 FFI（对齐现有测试风格）；三端共用同一套逻辑，
// Windows 分支（schema 同构 + 下载/校验复用）天然被同套用例覆盖。

import 'package:eterm/services/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

UpdateInfo _info({int build = 3, String version = '1.0.2'}) => UpdateInfo(
      version: version,
      build: build,
      url: 'https://hub.example.com/updates/eterm-android.apk',
      sha256: 'a' * 64,
    );

void main() {
  group('isNewer：build 号唯一权威（方案 §3）', () {
    test('build 更大 → 有新版本', () {
      expect(isNewer(_info(build: 4), currentBuild: 3), isTrue);
    });
    test('build 相等 → 不更新', () {
      expect(isNewer(_info(build: 3), currentBuild: 3), isFalse);
    });
    test('build 更小 → 不更新（拒绝降级）', () {
      expect(isNewer(_info(build: 2), currentBuild: 3), isFalse);
    });
  });

  group('UpdateInfo.tryParse：合法/缺字段/畸形', () {
    test('合法 JSON 解析出全部字段', () {
      final info = UpdateInfo.tryParse(const {
        'version': '1.0.2',
        'build': 3,
        'url': 'https://x/a.apk',
        'sha256': 'abc',
        'size': 79075407,
        'notes': '修复崩溃',
        'published_at': '2026-11-20T13:00:00+08:00',
      });
      expect(info, isNotNull);
      expect(info!.version, '1.0.2');
      expect(info.build, 3);
      expect(info.url, 'https://x/a.apk');
      expect(info.sha256, 'abc');
      expect(info.size, 79075407);
      expect(info.notes, '修复崩溃');
      expect(info.publishedAt, '2026-11-20T13:00:00+08:00');
    });
    test('可选字段缺省（Windows 元数据口径：无 published_at/notes）', () {
      final info = UpdateInfo.tryParse(
          {'version': '1.0.2', 'build': 3, 'url': 'https://x/e.exe', 'sha256': 'abc'});
      expect(info, isNotNull);
      expect(info!.size, 0);
      expect(info.notes, '');
      expect(info.publishedAt, isNull);
    });
    test('缺任一必填字段 → null', () {
      expect(UpdateInfo.tryParse({'build': 3, 'url': 'u', 'sha256': 's'}), isNull);
      expect(UpdateInfo.tryParse({'version': 'v', 'url': 'u', 'sha256': 's'}), isNull);
      expect(UpdateInfo.tryParse({'version': 'v', 'build': 3, 'sha256': 's'}), isNull);
      expect(UpdateInfo.tryParse({'version': 'v', 'build': 3, 'url': 'u'}), isNull);
    });
    test('类型不符/空值 → null', () {
      expect(
          UpdateInfo.tryParse({'version': 'v', 'build': '3', 'url': 'u', 'sha256': 's'}),
          isNull);
      expect(UpdateInfo.tryParse({'version': '', 'build': 3, 'url': 'u', 'sha256': 's'}),
          isNull);
    });
    test('build 为小数 → 截断取整（容错不拒绝，评审 P3-10 口径锁定）', () {
      final info =
          UpdateInfo.tryParse({'version': 'v', 'build': 3.0, 'url': 'u', 'sha256': 's'});
      expect(info, isNotNull);
      expect(info!.build, 3);
    });
    test('畸形/空响应 → null', () {
      expect(UpdateInfo.tryParse(null), isNull);
      expect(UpdateInfo.tryParse('garbage'), isNull);
      expect(UpdateInfo.tryParse([1, 2, 3]), isNull);
      expect(UpdateInfo.tryParse(<String, dynamic>{}), isNull);
    });
  });

  group('isSameSha256：下载完整性比对', () {
    test('匹配（大小写/首尾空白不敏感）', () {
      expect(isSameSha256('ABCdef123', ' abcdef123 '), isTrue);
    });
    test('不匹配 → false', () {
      expect(isSameSha256('aaa', 'bbb'), isFalse);
    });
    test('空期望串不匹配任何非空实际值', () {
      expect(isSameSha256('abc', ''), isFalse);
    });
  });

  group('shouldCheck：24h 节流（方案 §5.2）', () {
    const interval = Duration(hours: 24);
    test('首次（无记录）→ 查', () {
      expect(shouldCheck(lastCheckMs: 0, nowMs: 1000), isTrue);
    });
    test('lastCheckMs 为负（脏数据）→ 查', () {
      expect(shouldCheck(lastCheckMs: -1, nowMs: 1000), isTrue);
    });
    test('不足 24h → 不查', () {
      const now = 1000000;
      expect(shouldCheck(lastCheckMs: now, nowMs: now + interval.inMilliseconds - 1),
          isFalse);
    });
    test('恰好 24h → 查', () {
      const now = 1000000;
      expect(shouldCheck(lastCheckMs: now, nowMs: now + interval.inMilliseconds), isTrue);
    });
    test('超过 24h 1ms → 查', () {
      const now = 1000000;
      expect(shouldCheck(lastCheckMs: now, nowMs: now + interval.inMilliseconds + 1),
          isTrue);
    });
  });
}
