// 应用内自动更新（Android + Windows；macOS 走 Sparkle 2，见 macos/Runner/AppDelegate.swift）。
// 设计与契约见 docs/plan/eterm-自动更新方案.md §5/§6/§5.3：
//  - 三端共用一套检查/下载/校验纯逻辑（isNewer/shouldCheck/sha256 比对），仅「安装」一步平台分支；
//  - 元数据为 nginx /updates/ 静态 JSON（eterm-android.json / eterm-windows.json，schema 同构）；
//  - build 号（versionCode）是新旧判定唯一权威；检查失败一律静默/轻提示，绝不影响登录同步连接；
//  - 下载沿用 `.eterm-part` 暂存 + 完成改名约定（与 rust/api/sftp.rs 同款；取消/校验失败即删）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../src/rust/api/local.dart' as local;

const _kMetaBase = 'https://eterm.etarch.cn/updates';
const _kLastCheckKey = 'app.update.last_check';

/// 更新元数据（方案 §4.1/§4.3）。必填：version/build/url/sha256；
/// size/notes/published_at 可选（Windows JSON 的 notes/published_at 可缺省）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.url,
    required this.sha256,
    this.size = 0,
    this.notes = '',
    this.publishedAt,
  });

  final String version; // "1.0.2" 展示用
  final int build; // versionCode，判定权威
  final String url;
  final String sha256;
  final int size;
  final String notes;
  final String? publishedAt;

  /// 严格解析：任一必填字段缺失/类型不符 → null（调用方按检查失败处理）。
  static UpdateInfo? tryParse(Object? value) {
    if (value is! Map) return null;
    final version = value['version'];
    final build = value['build'];
    final url = value['url'];
    final sha256 = value['sha256'];
    if (version is! String || version.isEmpty) return null;
    if (build is! num) return null;
    if (url is! String || url.isEmpty) return null;
    if (sha256 is! String || sha256.isEmpty) return null;
    return UpdateInfo(
      version: version,
      build: build.toInt(),
      url: url,
      sha256: sha256,
      size: value['size'] is num ? (value['size'] as num).toInt() : 0,
      notes: value['notes'] is String ? value['notes'] as String : '',
      publishedAt: value['published_at'] is String ? value['published_at'] as String : null,
    );
  }
}

/// 新旧判定唯一权威：build 更大才算新；相等/更小 → 不更新（方案 §3 设计原则）。
bool isNewer(UpdateInfo info, {required int currentBuild}) => info.build > currentBuild;

/// 节流纯函数：距上次检查不足 interval 则不查；lastCheckMs<=0 视为首次。
bool shouldCheck({
  required int lastCheckMs,
  required int nowMs,
  Duration interval = const Duration(hours: 24),
}) =>
    lastCheckMs <= 0 || nowMs - lastCheckMs >= interval.inMilliseconds;

/// sha256 十六进制比对（大小写不敏感，允许首尾空白）。
bool isSameSha256(String actualHex, String expectedHex) =>
    actualHex.toLowerCase() == expectedHex.trim().toLowerCase();

enum UpdateCheckStatus { newer, upToDate, failed }

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.info});
  final UpdateCheckStatus status;
  final UpdateInfo? info;
}

/// 下载/校验失败（暂存文件已清理；消息可直接给 SnackBar）。
class UpdateDownloadException implements Exception {
  UpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 用户主动取消（非错误：调用方静默收场即可）。
class UpdateCancelledException implements Exception {
  @override
  String toString() => '下载已取消';
}

enum UpdateInstallAck { started, needPermission, error }

/// sha256 分块收集器：close() 时 package:crypto 会把最终 Digest 推进来。
class _DigestCollector implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

class AppUpdate {
  AppUpdate._();
  static final AppUpdate instance = AppUpdate._();

  HttpClient? _http;
  HttpClient get _client =>
      _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 8);

  static const _channel = MethodChannel('eterm/update');
  bool _channelHooked = false;

  /// Android 原生安装结果回传（session commit 后系统安装界面的成功/失败）。
  /// UI 层设置；app_update 只负责转发（原生侧经 onInstallStatus 回来）。
  static void Function(int code, String message)? onAndroidInstallStatus;

  bool _downloadCancelled = false;
  bool _downloading = false; // 单飞守卫：并发下载会对同一 .eterm-part 交错写（评审 P1-2）

  /// 平台闸（方案 §5.1）：Android/Windows 启用；macOS 由 Sparkle 自管，其余平台无更新。
  bool get isSupported => Platform.isAndroid || Platform.isWindows;

  String get _metaUrl => Platform.isAndroid
      ? '$_kMetaBase/eterm-android.json'
      : '$_kMetaBase/eterm-windows.json';

  void _hookChannel() {
    if (_channelHooked) return;
    _channelHooked = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInstallStatus') {
        final args = call.arguments;
        final code = args is Map ? (args['code'] as num?)?.toInt() ?? -1 : -1;
        final message = args is Map ? '${args['message'] ?? ''}' : '';
        onAndroidInstallStatus?.call(code, message);
      }
    });
  }

  /// 当前 build 号（pubspec 的 N，三端唯一事实源）。
  Future<int> currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// 检查更新。返回三态：newer / upToDate / failed（网络/元数据异常一律 failed，不抛）。
  /// [respectThrottle] 启动静默检查传 true（24h 节流，成功后才记时间戳）；手动检查传 false。
  Future<UpdateCheckResult> check({bool respectThrottle = true}) async {
    if (!isSupported) return const UpdateCheckResult(UpdateCheckStatus.upToDate);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (respectThrottle) {
      final last = int.tryParse(local.kvGet(key: _kLastCheckKey)) ?? 0;
      if (!shouldCheck(lastCheckMs: last, nowMs: now)) {
        return const UpdateCheckResult(UpdateCheckStatus.upToDate);
      }
    }
    try {
      final req = await _client.getUrl(Uri.parse(_metaUrl));
      final res =
          await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        // 非 200 也要把响应消费掉，连接才能回池（评审 P2-2）
        await res.drain<void>().catchError((_) {});
        return const UpdateCheckResult(UpdateCheckStatus.failed);
      }
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
      final info = UpdateInfo.tryParse(jsonDecode(text));
      if (info == null) return const UpdateCheckResult(UpdateCheckStatus.failed);
      final build = await currentBuild();
      // 检查成功即记时间戳（无论是否有新版本）；失败不记，下次启动尽快重试
      local.kvPut(key: _kLastCheckKey, value: '$now');
      if (!isNewer(info, currentBuild: build)) {
        return const UpdateCheckResult(UpdateCheckStatus.upToDate);
      }
      return UpdateCheckResult(UpdateCheckStatus.newer, info: info);
    } catch (_) {
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }
  }

  /// 流式下载安装包：`.eterm-part` 暂存 → 边下边算 sha256 → 校验 → 改名。
  /// 返回最终文件路径；取消抛 UpdateCancelledException，其余失败抛
  /// UpdateDownloadException（两种情况暂存文件都已删除，方案 §5.1/§12）。
  Future<String> download(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
  }) async {
    if (_downloading) {
      throw UpdateDownloadException('已有下载正在进行');
    }
    _downloading = true;
    try {
      return await _downloadInner(info, onProgress: onProgress);
    } finally {
      _downloading = false;
    }
  }

  Future<String> _downloadInner(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = await _downloadDir();
    await dir.create(recursive: true);
    final name = Platform.isAndroid
        ? 'eterm-${info.version}-${info.build}.apk'
        : 'eterm-windows-setup.exe'; // Windows 固定名覆盖写（方案 §5.3）
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    final part = File('${target.path}.eterm-part');
    _downloadCancelled = false;
    IOSink? sink;
    try {
      final req = await _client.openUrl('GET', Uri.parse(info.url));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        // 非 200 也要把响应消费掉，连接才能回池（评审 P2-2）
        await res.drain<void>().catchError((_) {});
        throw UpdateDownloadException('下载失败 HTTP ${res.statusCode}');
      }
      final total =
          res.contentLength > 0 ? res.contentLength : null;
      final collector = _DigestCollector();
      final digestSink = sha256.startChunkedConversion(collector);
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in res) {
        if (_downloadCancelled) throw UpdateCancelledException();
        sink.add(chunk);
        digestSink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      digestSink.close();
      final actual = collector.digest?.toString() ?? '';
      if (!isSameSha256(actual, info.sha256)) {
        throw UpdateDownloadException('安装包校验失败（sha256 不一致）');
      }
      // 校验通过才落正式名；旧包存在则覆盖
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      return target.path;
    } catch (e) {
      // 取消/失败即删暂存（方案 §12：不留半包大文件）
      try {
        if (sink != null) await sink.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 用户取消下载（download 的流循环在下一个分片抛 UpdateCancelledException）。
  void cancelDownload() => _downloadCancelled = true;

  /// 安装成功后清理下载目录（方案 §12：不留累积的旧包；Windows 固定名覆盖写无累积）。
  Future<void> cleanupAfterInstall() async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await _downloadDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) {
      // 应用专属外部目录 Android/data/<pkg>/files/update/（免运行时权限，
      // 与 SFTP 下载落盘约定一致，方案 §5.1）
      final ext = await getExternalStorageDirectory();
      if (ext == null) {
        throw UpdateDownloadException('外部存储不可用');
      }
      return Directory('${ext.path}${Platform.pathSeparator}update');
    }
    // Windows：临时目录固定覆盖写，校验失败即删、不占用户数据区（方案 §5.3）
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}${Platform.pathSeparator}eterm-update');
  }

  /// 安装已下载并校验通过的包（方案 §6 session / §5.3 spawn）。
  /// Android 返回 needPermission 时由 UI 引导授权后重试；
  /// Windows 分支不返回（spawn 静默安装器后本进程 exit(0)，装完由安装器自动重启）。
  Future<UpdateInstallAck> install(String path) async {
    if (Platform.isAndroid) {
      _hookChannel();
      final ack = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('installApk', path);
      final status = ack?['status'] as String? ?? 'error';
      switch (status) {
        case 'need_permission':
          return UpdateInstallAck.needPermission;
        case 'started':
          return UpdateInstallAck.started;
        default:
          return UpdateInstallAck.error;
      }
    }
    // Windows：先退出再装（方案 §5.3 固定时序）。detached 让安装器独立于本进程存活；
    // 静默模式跳过安装器运行中检测，spawn 后稍候立即退出兜底竞态（§12）。
    await Process.start(path, const ['/S'], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
