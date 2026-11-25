// SFTP 传输队列（M3→v2）：入队 → 并发受限执行 → 进度/取消/重试。
// v2（任务清单 #7/#8）：任务自带会话/路径（支持 远端↔远端 直传、目录递归复制、
// 目录打包压缩下载），队列不再绑定单一会话。任务类型：
//   upload      本地文件 → 远端
//   download    远端文件 → 本地
//   copy        远端文件 → 远端（客户端内存中转，B 侧 .eterm-part 暂存）
//   tarDownload 远端目录 → 本地 <名>.tar.gz（exec tar -czf -，流式，不可续传）
//   copyDir     远端目录 → 远端（递归逐文件，目标同大小跳过 → 重试可续）
// Rust 侧语义：覆盖写 + `<目标>.eterm-part` 暂存；resume=true 从暂存续传（tar/copyDir 除外）。
// 冲突策略（skip/overwrite/rename）在入队前由 UI 决策。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:eterm/src/rust/api/sftp.dart' as sftp;

enum SftpJobState { queued, running, done, failed, canceled }

enum SftpJobKind { upload, download, copy, tarDownload, copyDir }

/// 冲突策略：入队时目标侧已存在同名文件时的处置。
enum ConflictAction { skip, overwrite, rename }

/// 远端主机规格（tar 打包需独立连接，任务随身携带）。
class SftpRemoteSpec {
  const SftpRemoteSpec({
    required this.host,
    required this.port,
    required this.user,
    required this.authKind,
    required this.secret,
  });
  final String host;
  final int port;
  final String user;
  final String authKind;
  final String secret;
}

/// 跨页面共享的传输任务 id 序列（Rust 取消注册表按 u32 键，各页新任务取新 id）。
int _jobSeq = DateTime.now().microsecondsSinceEpoch & 0x3FFFFFFF;
int freshSftpJobId() => _jobSeq = (_jobSeq + 1) & 0x3FFFFFFF;

class SftpTransferJob {
  SftpTransferJob({
    required this.jobId,
    required this.kind,
    required this.pathFrom,
    required this.pathTo,
    required this.name,
    this.sessionFrom,
    this.sessionTo,
    this.specFrom,
    this.resume = false,
  });

  /// Rust 取消注册表的键。重试时换新 id，避免与已清理的旧注册混淆。
  int jobId;
  final SftpJobKind kind;
  final String pathFrom;
  final String pathTo;
  /// 展示名（两端同名冲突改写后以实际入队名为准）。
  final String name;
  /// 源会话（null = 本地）。tarDownload 用 specFrom 独立建连。
  final BigInt? sessionFrom;
  /// 目标会话（null = 本地）。
  final BigInt? sessionTo;
  final SftpRemoteSpec? specFrom;
  /// 重试（或用户显式续传）时置 true：Rust 从 .eterm-part 暂存续传。
  bool resume;
  SftpJobState state = SftpJobState.queued;
  int transferred = 0;
  int total = 0; // 0 = 未知（首个进度事件补齐）
  String? error;

  /// 目标侧路径（去重键：上传=远端路径/下载=本地路径/复制=目标路径）。
  String get targetPath => pathTo;

  bool get isTerminal =>
      state == SftpJobState.done ||
      state == SftpJobState.failed ||
      state == SftpJobState.canceled;

  StreamSubscription<sftp.SftpProgress>? _sub;
}

/// 传输通道抽象：生产走 frb 绑定，测试注入 fake（驱动进度/错误时序）。
abstract class SftpTransport {
  Stream<sftp.SftpProgress> start(SftpTransferJob job);
  void cancel({required int jobId});
}

class FrbSftpTransport implements SftpTransport {
  const FrbSftpTransport();

  @override
  Stream<sftp.SftpProgress> start(SftpTransferJob j) => switch (j.kind) {
        SftpJobKind.upload => sftp.sftpUpload(
            id: j.sessionTo!,
            jobId: j.jobId,
            localPath: j.pathFrom,
            remotePath: j.pathTo,
            resume: j.resume,
          ),
        SftpJobKind.download => sftp.sftpDownload(
            id: j.sessionFrom!,
            jobId: j.jobId,
            remotePath: j.pathFrom,
            localPath: j.pathTo,
            resume: j.resume,
          ),
        SftpJobKind.copy => sftp.sftpCopy(
            idFrom: j.sessionFrom!,
            jobId: j.jobId,
            pathFrom: j.pathFrom,
            idTo: j.sessionTo!,
            pathTo: j.pathTo,
            resume: j.resume,
          ),
        SftpJobKind.tarDownload => sftp.sftpTarDownload(
            host: j.specFrom!.host,
            port: j.specFrom!.port,
            user: j.specFrom!.user,
            authKind: j.specFrom!.authKind,
            secret: j.specFrom!.secret,
            jobId: j.jobId,
            remoteDir: j.pathFrom,
            localPath: j.pathTo,
          ),
        SftpJobKind.copyDir => sftp.sftpCopyDir(
            idFrom: j.sessionFrom!,
            jobId: j.jobId,
            dirFrom: j.pathFrom,
            idTo: j.sessionTo!,
            dirTo: j.pathTo,
          ),
      };

  @override
  void cancel({required int jobId}) => sftp.sftpTransferCancel(jobId: jobId);
}

class SftpTransferQueue extends ChangeNotifier {
  SftpTransferQueue({
    this.concurrency = 2,
    SftpTransport? transport,
  }) : _transport = transport ?? const FrbSftpTransport();

  final int concurrency;
  final SftpTransport _transport;

  final List<SftpTransferJob> jobs = [];
  bool _disposed = false;

  /// dispose 后取消/失败等迟到流事件只改任务字段，不再通知（避免 assert）。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 新建任务（默认全新传输：Rust 侧清掉同名暂存从头写）。
  /// 断点续传只经 retry()（resume=true 从 .eterm-part 续）——
  /// 全新入队走 resume=false，避免同名旧暂存来源不明时续错数据。
  /// 同 kind、同目标路径（targetPath）的去重：已有非终态任务时返回 null 并拒绝入队
  /// （两个任务并发写同一 .eterm-part 会损坏数据）。队列已 dispose 时同样返回 null。
  SftpTransferJob? enqueue({
    required SftpJobKind kind,
    required String pathFrom,
    required String pathTo,
    required String name,
    BigInt? sessionFrom,
    BigInt? sessionTo,
    SftpRemoteSpec? specFrom,
    bool resume = false,
  }) {
    if (_disposed) return null;
    // 去重键 = (目标会话, 目标路径)：同一写入端同一目标会并发写同一 .eterm-part
    // （与 kind 无关：upload 与 copy 目标相同时同样冲突）；不同会话互不相干。
    final targetKey = sessionTo?.toString() ?? 'local';
    for (final j in jobs) {
      if (j.isTerminal) continue;
      final jKey = j.sessionTo?.toString() ?? 'local';
      if (jKey == targetKey && j.targetPath == pathTo) return null;
    }
    final job = SftpTransferJob(
      jobId: freshSftpJobId(),
      kind: kind,
      pathFrom: pathFrom,
      pathTo: pathTo,
      name: name,
      sessionFrom: sessionFrom,
      sessionTo: sessionTo,
      specFrom: specFrom,
      resume: resume,
    );
    jobs.add(job);
    _notify();
    _pump();
    return job;
  }

  /// 取消（排队中直接出队态置取消；运行中经 Rust 取消旗标在分块边界停下）。
  void cancel(SftpTransferJob job) {
    if (_disposed || job.isTerminal) return;
    if (job.state == SftpJobState.queued) {
      job.state = SftpJobState.canceled;
      _notify();
      return;
    }
    _transport.cancel(jobId: job.jobId);
  }

  /// 失败/取消重试：换新 jobId，从暂存续传（resume=true）。
  /// 仅 failed/canceled 可重试（对 done/queued/running 重试为 no-op）。
  /// tar 下载与目录复制为流式/逐文件语义：重试为全新执行（Rust 侧各自处理续传）。
  /// 重试同样遵守同目标去重（与 enqueue 同口径：(目标会话, 目标路径)，跨 kind）：
  /// 失败任务长期保留在列表（clearFinished 刻意保留失败），若用户已为同一目标
  /// 重新入队（哪怕换了传输类型），重试会造成并发写同一 .eterm-part → 静默拒绝。
  void retry(SftpTransferJob job) {
    if (_disposed) return;
    if (job.state != SftpJobState.failed &&
        job.state != SftpJobState.canceled) {
      return;
    }
    final jobKey = job.sessionTo?.toString() ?? 'local';
    for (final j in jobs) {
      if (identical(j, job) || j.isTerminal) continue;
      final jKey = j.sessionTo?.toString() ?? 'local';
      if (jKey == jobKey && j.targetPath == job.targetPath) return;
    }
    job.jobId = freshSftpJobId();
    job.resume = job.kind == SftpJobKind.upload ||
        job.kind == SftpJobKind.download ||
        job.kind == SftpJobKind.copy;
    job.state = SftpJobState.queued;
    job.error = null;
    _notify();
    _pump();
  }

  /// 清理已完成与已取消（保留失败，提示用户可重试）。
  void clearFinished() {
    if (_disposed) return;
    jobs.removeWhere((j) =>
        j.state == SftpJobState.done || j.state == SftpJobState.canceled);
    _notify();
  }

  int get activeCount =>
      jobs.where((j) => !j.isTerminal).length;

  /// 页面销毁：全量取消（运行中发 Rust 取消，排队中直接置态），等待流收尾。
  /// 可与 dispose() 同步调用：迟到事件只改字段，不再通知。
  Future<void> shutdown() async {
    final subs = <StreamSubscription<sftp.SftpProgress>>[];
    for (final j in jobs) {
      if (j.isTerminal) continue;
      if (j.state == SftpJobState.running) {
        _transport.cancel(jobId: j.jobId);
        if (j._sub != null) subs.add(j._sub!);
      }
      // 订阅随后即取消，收不到流错误 → 直接置终态（Rust 侧旗标仍会在分块边界停下）
      j.state = SftpJobState.canceled;
    }
    _notify();
    for (final s in subs) {
      await s.cancel();
    }
  }

  void _pump() {
    while (jobs.where((j) => j.state == SftpJobState.running).length <
        concurrency) {
      final next = jobs.firstWhereOrNull((j) => j.state == SftpJobState.queued);
      if (next == null) return;
      _start(next);
    }
  }

  void _start(SftpTransferJob job) {
    job.state = SftpJobState.running;
    _notify();
    final stream = _transport.start(job);
    // 捕获本订阅句柄：onDone 校验归属，防重试后旧流迟到 onDone 误标新尝试
    late final StreamSubscription<sftp.SftpProgress> sub;
    sub = stream.listen((p) {
      if (p.jobId != job.jobId) return; // 旧尝试的迟到事件（重试后）
      job.transferred = p.transferred.toInt();
      job.total = p.total.toInt();
      _notify();
    }, onError: (Object e) {
      // Rust 取消的错误文本含「取消」→ 映射为 canceled（暂存保留，可续传重试）
      final msg = '$e';
      final canceled = msg.contains('取消');
      job.state = canceled ? SftpJobState.canceled : SftpJobState.failed;
      job.error = msg;
      _notify();
      _pump();
    }, onDone: () {
      if (job._sub == sub && job.state == SftpJobState.running) {
        job.state = SftpJobState.done;
        _notify();
        _pump();
      }
    });
    job._sub = sub;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 为 [desired] 取第一个可用名字（传输冲突自动改名用）。
/// 可用 = 不在 [taken] 中且 [exists] 探活为 false（本机目标要查文件系统，
/// 远端目标只查 taken）。desired 本身可用时原样返回。
/// 命名规则：a.txt → a (1).txt；隐藏文件（".name"）整体视作无扩展名处理。
String allocateUniqueName(
  String desired, {
  required Set<String> taken,
  bool Function(String name)? exists,
}) {
  bool free(String n) => !taken.contains(n) && !(exists?.call(n) ?? false);
  if (free(desired)) return desired;
  final dot = desired.lastIndexOf('.');
  final base = dot <= 0 ? desired : desired.substring(0, dot);
  final ext = dot <= 0 ? '' : desired.substring(dot);
  var i = 1;
  while (true) {
    final cand = '$base ($i)$ext';
    if (free(cand)) return cand;
    i++;
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
