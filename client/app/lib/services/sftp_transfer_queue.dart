// SFTP 传输队列（M3）：入队 → 并发受限执行 → 进度/取消/重试（断点续传）。
// 队列本身无会话生命周期：持有 sessionId，页面 dispose 时 shutdown() 全量取消。
// Rust 侧语义（api/sftp.rs）：覆盖写 + `<目标>.eterm-part` 暂存；resume=true 从暂存续传，
// 取消/失败保留暂存 → 重试自动续。冲突策略（skip/overwrite/rename）在入队前由 UI 决策。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:eterm/src/rust/api/sftp.dart' as sftp;

enum SftpJobState { queued, running, done, failed, canceled }

enum SftpDirection { upload, download }

/// 冲突策略：入队时目标侧已存在同名文件时的处置。
enum ConflictAction { skip, overwrite, rename }

/// 跨页面共享的传输任务 id 序列（Rust 取消注册表按 u32 键，各页新任务取新 id）。
int _jobSeq = DateTime.now().microsecondsSinceEpoch & 0x3FFFFFFF;
int freshSftpJobId() => _jobSeq = (_jobSeq + 1) & 0x3FFFFFFF;

class SftpTransferJob {
  SftpTransferJob({
    required this.jobId,
    required this.direction,
    required this.localPath,
    required this.remotePath,
    required this.name,
    this.resume = false,
  });

  /// Rust 取消注册表的键。重试时换新 id，避免与已清理的旧注册混淆。
  int jobId;
  final SftpDirection direction;
  final String localPath;
  final String remotePath;
  /// 展示名（两端同名冲突改写后以实际入队名为准）。
  final String name;
  /// 重试（或用户显式续传）时置 true：Rust 从 .eterm-part 暂存续传。
  bool resume;
  SftpJobState state = SftpJobState.queued;
  int transferred = 0;
  int total = 0; // 0 = 未知（首个进度事件补齐）
  String? error;

  bool get isTerminal =>
      state == SftpJobState.done ||
      state == SftpJobState.failed ||
      state == SftpJobState.canceled;

  StreamSubscription<sftp.SftpProgress>? _sub;
}

/// 传输通道抽象：生产走 frb 绑定，测试注入 fake（驱动进度/错误时序）。
abstract class SftpTransport {
  Stream<sftp.SftpProgress> upload({
    required BigInt id,
    required int jobId,
    required String localPath,
    required String remotePath,
    required bool resume,
  });

  Stream<sftp.SftpProgress> download({
    required BigInt id,
    required int jobId,
    required String remotePath,
    required String localPath,
    required bool resume,
  });

  void cancel({required int jobId});
}

class FrbSftpTransport implements SftpTransport {
  const FrbSftpTransport();

  @override
  Stream<sftp.SftpProgress> upload({
    required BigInt id,
    required int jobId,
    required String localPath,
    required String remotePath,
    required bool resume,
  }) =>
      sftp.sftpUpload(
        id: id,
        jobId: jobId,
        localPath: localPath,
        remotePath: remotePath,
        resume: resume,
      );

  @override
  Stream<sftp.SftpProgress> download({
    required BigInt id,
    required int jobId,
    required String remotePath,
    required String localPath,
    required bool resume,
  }) =>
      sftp.sftpDownload(
        id: id,
        jobId: jobId,
        remotePath: remotePath,
        localPath: localPath,
        resume: resume,
      );

  @override
  void cancel({required int jobId}) => sftp.sftpTransferCancel(jobId: jobId);
}

class SftpTransferQueue extends ChangeNotifier {
  SftpTransferQueue({
    required this.sessionId,
    this.concurrency = 2,
    SftpTransport? transport,
  }) : _transport = transport ?? const FrbSftpTransport();

  final BigInt sessionId;
  final int concurrency;
  final SftpTransport _transport;

  final List<SftpTransferJob> jobs = [];
  bool _disposed = false;

  /// dispose 后取消/失败等迟到流事件只改任务字段，不再通知（避免 assert）。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 新建任务（默认全新传输：Rust 侧清掉同名暂存从头写）。
  /// 断点续传只经 retry()（resume=true 从 .eterm-part 暂存续）——
  /// 全新入队走 resume=false，避免同名旧暂存来源不明时续错数据。
  /// 同方向、同目标路径（上传=远端路径/下载=本地路径）的去重：已有非终态任务时
  /// 返回 null 并拒绝入队（两个任务并发写同一 .eterm-part 会损坏数据）。
  /// 队列已 dispose 时同样返回 null。
  SftpTransferJob? enqueue({
    required SftpDirection direction,
    required String localPath,
    required String remotePath,
    required String name,
    bool resume = false,
  }) {
    if (_disposed) return null;
    final target = direction == SftpDirection.upload ? remotePath : localPath;
    for (final j in jobs) {
      if (j.isTerminal) continue;
      final jTarget =
          j.direction == SftpDirection.upload ? j.remotePath : j.localPath;
      if (j.direction == direction && jTarget == target) return null;
    }
    final job = SftpTransferJob(
      jobId: freshSftpJobId(),
      direction: direction,
      localPath: localPath,
      remotePath: remotePath,
      name: name,
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
  /// 重试同样遵守同目标去重：失败任务长期保留在列表（clearFinished 刻意保留失败），
  /// 若用户已为同一目标重新入队，重试会造成并发写同一 .eterm-part → 静默拒绝。
  void retry(SftpTransferJob job) {
    if (_disposed) return;
    if (job.state != SftpJobState.failed &&
        job.state != SftpJobState.canceled) {
      return;
    }
    final target =
        job.direction == SftpDirection.upload ? job.remotePath : job.localPath;
    for (final j in jobs) {
      if (identical(j, job) || j.isTerminal) continue;
      final jTarget =
          j.direction == SftpDirection.upload ? j.remotePath : j.localPath;
      if (j.direction == job.direction && jTarget == target) return;
    }
    job.jobId = freshSftpJobId();
    job.resume = true;
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
    final stream = job.direction == SftpDirection.upload
        ? _transport.upload(
            id: sessionId,
            jobId: job.jobId,
            localPath: job.localPath,
            remotePath: job.remotePath,
            resume: job.resume,
          )
        : _transport.download(
            id: sessionId,
            jobId: job.jobId,
            remotePath: job.remotePath,
            localPath: job.localPath,
            resume: job.resume,
          );
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

/// 目标名冲突时的自动改名：a.txt → a (1).txt；序号顺延避开 taken 中的所有名字。
/// 隐藏文件（".name"）整体视作无扩展名处理。
String nextAvailableName(Iterable<String> taken, String name) {
  final dot = name.lastIndexOf('.');
  final base = dot <= 0 ? name : name.substring(0, dot);
  final ext = dot <= 0 ? '' : name.substring(dot);
  var i = 1;
  while (true) {
    final cand = '$base ($i)$ext';
    if (!taken.contains(cand)) return cand;
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
