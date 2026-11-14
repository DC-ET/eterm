// Spike S3 集成测试（技术方案 §8）：frb 双端绑定可用性 + 流式接口延迟。
// 运行：flutter test integration_test/s3_frb_test.dart -d macos
// 通过标准：三个功能项正确；流式接口 < 5ms/帧。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:eterm/src/rust/api/simple.dart' as api;
import 'package:eterm/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('S3: ping / seal+open / streamEcho', (tester) async {
    // 1. 基础调用（sync FFI）
    expect(api.ping(msg: 's3'), 'pong: s3');

    // 2. 字段加解密往返（真实核心路径，v1 格式与服务端同构；边界为 UTF-8 字节）
    final key = Uint8List.fromList(List.filled(32, 7));
    final plain = Uint8List.fromList(utf8.encode('中文密文🔐'));
    final sealed = await api.sealField(key: key, plaintext: plain);
    expect(sealed.startsWith('v1:'), isTrue, reason: '密文应为 v1 前缀格式');
    final opened = await api.openField(key: key, sealed: sealed);
    expect(utf8.decode(opened), '中文密文🔐');

    // 3. 流式回显 + 逐帧延迟测量
    const n = 200;
    const size = 65536;
    final sw = Stopwatch()..start();
    final frames = <Uint8List>[];
    await for (final f in api.streamEcho(count: n, size: BigInt.from(size))) {
      frames.add(f);
      if (frames.length >= n) break;
    }
    sw.stop();
    expect(frames.length, n);
    // 帧序号连续性
    for (var i = 0; i < n; i++) {
      expect(frames[i][0], i & 0xFF, reason: '第 $i 帧序号不符');
    }
    final perFrameMs = sw.elapsedMicroseconds / n / 1000.0;
    // ignore: avoid_print
    print('S3_STREAM: $n 帧 × $size B，总耗时 ${sw.elapsedMilliseconds}ms，'
        '每帧 ${perFrameMs.toStringAsFixed(3)}ms，'
        '吞吐 ${(n * size / 1024 / 1024) / (sw.elapsedMicroseconds / 1e6)}.toStringAsFixed(0)}MB/s');
    expect(perFrameMs, lessThan(5.0), reason: '流式接口延迟应 < 5ms/帧');
  });
}
