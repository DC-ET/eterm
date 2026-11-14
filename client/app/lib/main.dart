// eterm 客户端（M0）。
// 当前为 S3 探针屏：验证 frb FFI 链路（ping / seal+open / streamEcho 延迟）。
// 登录页 / Host 列表 / 终端页随 M0 骨架推进逐步替换本文件。

import 'dart:typed_data';

import 'package:eterm/src/rust/api/simple.dart' as api;
import 'package:eterm/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const ProbeApp());
}

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = ['探针运行中…'];

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String s) => setState(() => _lines.add(s));

  Future<void> _run() async {
    try {
      // 1. sync FFI
      final pong = api.ping(msg: 'eterm');
      _log('ping: $pong');

      // 2. 字段加解密（真实核心路径，v1 格式）
      final key = Uint8List.fromList(List.filled(32, 7));
      final sealed = await api.sealField(key: key, plaintext: '中文密文🔐'.codeUnits);
      _log('seal: ${sealed.substring(0, 24)}… (${sealed.length} chars)');
      final opened = await api.openField(key: key, sealed: sealed);
      _log('open: ${String.fromCharCodes(opened)}');

      // 3. 流式回显延迟
      const n = 200;
      const size = 65536;
      final sw = Stopwatch()..start();
      var count = 0;
      await for (final f in api.streamEcho(count: n, size: BigInt.from(size))) {
        count++;
        if (count >= n) break;
      }
      sw.stop();
      final per = sw.elapsedMicroseconds / n / 1000.0;
      _log('stream: $n 帧 × 64KB，每帧 ${per.toStringAsFixed(3)}ms '
          '(${per < 5 ? "达标 <5ms" : "未达标"})');
      _log('S3 探针完成');
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eterm · S3 探针',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('eterm · S3 frb 探针')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))],
        ),
      ),
    );
  }
}
