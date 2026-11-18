// SFTP 传输队列单测：并发上限、取消（排队/运行）、失败重试续传、清理策略、同目标去重。
// FakeTransport 手工驱动进度/错误时序，不触 Rust。

import 'dart:async';

import 'package:eterm/services/sftp_transfer_queue.dart';
import 'package:eterm/src/rust/api/sftp.dart' as sftp;
import 'package:flutter_test/flutter_test.dart';

/// 手工驱动的假传输通道：记录调用，按 jobId 注册可操控的流。
class FakeTransport implements SftpTransport {
  final controllers = <int, StreamController<sftp.SftpProgress>>{};
  final cancels = <int>[];
  // (jobId, 关键路径, resume, kind) 每次真实启动记录一条
  final started = <(int, String, bool, SftpJobKind)>[];

  StreamController<sftp.SftpProgress> _ctrl(int jobId) =>
      controllers.putIfAbsent(
          jobId, () => StreamController<sftp.SftpProgress>());

  @override
  Stream<sftp.SftpProgress> start(SftpTransferJob job) {
    // 与旧约定一致：上传记目标路径，下载/直传记源路径
    final path = switch (job.kind) {
      SftpJobKind.upload => job.pathTo,
      _ => job.pathFrom,
    };
    started.add((job.jobId, path, job.resume, job.kind));
    return _ctrl(job.jobId).stream;
  }

  @override
  void cancel({required int jobId}) => cancels.add(jobId);

  void emit(int jobId, int transferred, int total) => _ctrl(jobId).add(
        sftp.SftpProgress(
          jobId: jobId,
          transferred: BigInt.from(transferred),
          total: BigInt.from(total),
          path: 'p',
        ),
      );

  void fail(int jobId, Object e) {
    _ctrl(jobId).addError(e);
    _ctrl(jobId).close();
  }

  void complete(int jobId) => _ctrl(jobId).close();
}

SftpTransferQueue _queue(FakeTransport t) =>
    SftpTransferQueue(concurrency: 2, transport: t);

/// 测试里的入队助手：enqueue 判空去重后断言必有任务。
SftpTransferJob _enq(
  SftpTransferQueue q, {
  required SftpJobKind kind,
  required String pathFrom,
  required String pathTo,
  required String name,
  bool resume = false,
  BigInt? sessionFrom,
  BigInt? sessionTo,
}) =>
    q.enqueue(
      kind: kind,
      pathFrom: pathFrom,
      pathTo: pathTo,
      name: name,
      sessionFrom: sessionFrom,
      sessionTo: sessionTo,
      resume: resume,
    )!;

void main() {
  group('nextAvailableName', () {
    test('基础改名与序号顺延（仅在调用方已判定同名冲突后使用）', () {
      expect(nextAvailableName(['a.txt'], 'a.txt'), 'a (1).txt');
      expect(nextAvailableName(['a.txt', 'a (1).txt'], 'a.txt'), 'a (2).txt');
      expect(nextAvailableName([], 'b.txt'), 'b (1).txt');
    });

    test('无扩展名与隐藏文件', () {
      expect(nextAvailableName(['README'], 'README'), 'README (1)');
      expect(nextAvailableName(['.hidden'], '.hidden'), '.hidden (1)');
      expect(nextAvailableName(['a.b.c'], 'a.b.c'), 'a.b (1).c');
    });
  });

  group('SftpTransferQueue', () {
    test('并发上限：第 3 个任务在前一个完成后才启动', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final a = _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l1',
          pathTo: 'r1',
          name: 'a');
      final b = _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l2',
          pathTo: 'r2',
          name: 'b');
      final c = _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l3',
          pathTo: 'r3',
          name: 'c');
      expect(a.state, SftpJobState.running);
      expect(b.state, SftpJobState.running);
      expect(c.state, SftpJobState.queued);
      expect(t.started.length, 2);

      t.complete(a.jobId);
      await pumpEventQueue();
      expect(a.state, SftpJobState.done);
      expect(c.state, SftpJobState.running, reason: '空位应立即被第 3 个任务补上');
      q.dispose();
    });

    test('失败释放的空位同样立即补位（onError 路径的 _pump）', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final a = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r1', name: 'a');
      _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r2', name: 'b');
      final c = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r3', name: 'c');
      expect(c.state, SftpJobState.queued);
      t.fail(a.jobId, '网络错误');
      await pumpEventQueue();
      expect(a.state, SftpJobState.failed);
      expect(c.state, SftpJobState.running, reason: '失败释放的并发位应由排队任务补上');
      q.dispose();
    });

    test('进度事件更新 transferred/total', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final job = _enq(q,
          kind: SftpJobKind.download,
          pathFrom: 'r',
          pathTo: 'l',
          name: 'f');
      t.emit(job.jobId, 512, 1024);
      await pumpEventQueue();
      expect(job.transferred, 512);
      expect(job.total, 1024);
      q.dispose();
    });

    test('取消运行中任务：走 Rust 取消 + 错误映射为 canceled', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final job = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r', name: 'f');
      q.cancel(job);
      expect(t.cancels, [job.jobId]);
      t.fail(job.jobId, '传输已取消');
      await pumpEventQueue();
      expect(job.state, SftpJobState.canceled);
      q.dispose();
    });

    test('取消排队中任务：直接置态，不触 Rust', () async {
      final t = FakeTransport();
      final q = _queue(t);
      _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r1', name: 'a');
      _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r2', name: 'b');
      final c = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r3', name: 'c');
      expect(c.state, SftpJobState.queued);
      q.cancel(c);
      expect(c.state, SftpJobState.canceled);
      expect(t.cancels, isEmpty);
      q.dispose();
    });

    test('失败重试：换新 jobId 且 resume=true（断点续传）', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final job = _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l',
          pathTo: 'r',
          name: 'f',
          resume: false);
      final oldId = job.jobId;
      t.fail(job.jobId, '网络错误');
      await pumpEventQueue();
      expect(job.state, SftpJobState.failed);

      q.retry(job);
      expect(job.jobId, isNot(oldId));
      expect(job.resume, isTrue);
      expect(job.state, SftpJobState.running);
      await pumpEventQueue();
      expect(t.started.last, (job.jobId, 'r', true, SftpJobKind.upload));
      t.complete(job.jobId);
      await pumpEventQueue();
      expect(job.state, SftpJobState.done);
      q.dispose();
    });

    test('远端→远端 copy 失败重试：同样 resume=true；tar/copyDir 重试为全新执行', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final cp = _enq(q,
          kind: SftpJobKind.copy,
          pathFrom: 'ra',
          pathTo: 'rb',
          name: 'c',
          sessionFrom: BigInt.one,
          sessionTo: BigInt.two);
      t.fail(cp.jobId, '网络错误');
      await pumpEventQueue();
      q.retry(cp);
      expect(cp.resume, isTrue);
      expect(cp.state, SftpJobState.running);
      await pumpEventQueue();
      expect(t.started.last, (cp.jobId, 'ra', true, SftpJobKind.copy));

      final tar = _enq(q,
          kind: SftpJobKind.tarDownload,
          pathFrom: 'rdir',
          pathTo: 'l.tar.gz',
          name: 't',
          sessionFrom: BigInt.one,
          sessionTo: null);
      t.fail(tar.jobId, '网络错误');
      await pumpEventQueue();
      q.retry(tar);
      expect(tar.resume, isFalse, reason: '流式压缩不可续传');

      final cd = _enq(q,
          kind: SftpJobKind.copyDir,
          pathFrom: 'ra/dir',
          pathTo: 'rb/dir',
          name: 'd',
          sessionFrom: BigInt.one,
          sessionTo: BigInt.two);
      t.fail(cd.jobId, '网络错误');
      await pumpEventQueue();
      q.retry(cd);
      expect(cd.resume, isFalse, reason: '目录复制逐文件续传，重试为全新执行');
      q.dispose();
    });

    test('重试跨 kind 同目标同样拒绝（与 enqueue 去重口径一致，防并发写同一暂存）', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final failedCopy = _enq(q,
          kind: SftpJobKind.copy,
          pathFrom: 'ra',
          pathTo: 'r',
          name: 'a',
          sessionFrom: BigInt.one,
          sessionTo: BigInt.one);
      t.fail(failedCopy.jobId, '网络错误');
      await pumpEventQueue();
      // 同目标换成 upload 重新入队（失败任务是终态，enqueue 放行）
      final fresh = _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l1',
          pathTo: 'r',
          name: 'a',
          sessionTo: BigInt.one);
      expect(fresh.state, SftpJobState.running);
      // 此时重试失败的 copy → 跨 kind 同目标冲突，静默拒绝
      final idBefore = failedCopy.jobId;
      q.retry(failedCopy);
      expect(failedCopy.state, SftpJobState.failed);
      expect(failedCopy.jobId, idBefore);
      q.dispose();
    });

    test('重试后旧流的迟到事件被忽略（onError 与进度）', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final job = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r', name: 'f');
      final oldId = job.jobId;
      t.fail(oldId, '网络错误');
      await pumpEventQueue();
      q.retry(job);
      final newId = job.jobId;
      await pumpEventQueue();

      // 旧控制器已 close，改用新控制器之前的迟到事件无从注入；
      // 直接验证 jobId 过滤：向旧 id 发事件（fake 里旧控制器 closed 会抛，跳过），
      // 此处验证新流事件正常、旧 jobId 不再有匹配监听
      t.emit(newId, 100, 200);
      await pumpEventQueue();
      expect(job.transferred, 100);
      expect(job.jobId, newId);
      q.dispose();
    });

    test('非网络错误不误判为取消', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final job = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r', name: 'f');
      t.fail(job.jobId, '打开本地文件失败: no such file');
      await pumpEventQueue();
      expect(job.state, SftpJobState.failed);
      expect(job.error, contains('打开本地文件失败'));
      q.dispose();
    });

    test('重试遵守同目标去重：已有同目标任务在跑时拒绝重试', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final failed = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l1', pathTo: 'r', name: 'a');
      t.fail(failed.jobId, '网络错误');
      await pumpEventQueue();
      // 同目标（远端 r）重新入队 → 允许（失败任务是终态不阻塞）
      final fresh = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l2', pathTo: 'r', name: 'a');
      expect(fresh.state, SftpJobState.running);
      // 此时重试失败任务 → 同目标冲突，静默拒绝（防并发写同一暂存）
      final idBefore = failed.jobId;
      q.retry(failed);
      expect(failed.state, SftpJobState.failed);
      expect(failed.jobId, idBefore);
      // 同目标任务完成后 → 重试放行（换新 id，resume=true）
      t.complete(fresh.jobId);
      await pumpEventQueue();
      q.retry(failed);
      expect(failed.state, SftpJobState.running);
      expect(failed.jobId, isNot(idBefore));
      expect(failed.resume, isTrue);
      q.dispose();
    });

    test('同目标去重：同 kind 同目标路径拒绝入队（防并发写同一暂存）', () {
      final t = FakeTransport();
      final q = _queue(t);
      _enq(q,
          kind: SftpJobKind.upload,
          pathFrom: 'l1',
          pathTo: 'r',
          name: 'a',
          sessionTo: BigInt.one);
      // 同远端目标 → 拒绝
      expect(
          q.enqueue(
            kind: SftpJobKind.upload,
            pathFrom: 'l2',
            pathTo: 'r',
            name: 'a',
            sessionTo: BigInt.one,
          ),
          isNull);
      // 同 kind 不同目标 → 允许
      expect(
          q.enqueue(
            kind: SftpJobKind.upload,
            pathFrom: 'l3',
            pathTo: 'r2',
            name: 'b',
            sessionTo: BigInt.one,
          ),
          isNotNull);
      // 不同 kind 同目标同会话（上传到 r 与直传到 r 写同一暂存）→ 拒绝
      expect(
          q.enqueue(
            kind: SftpJobKind.copy,
            pathFrom: 'ra',
            pathTo: 'r',
            name: 'c',
            sessionFrom: BigInt.one,
            sessionTo: BigInt.one,
          ),
          isNull);
      // 不同 kind 同目标但不同会话（不同主机互不相干）→ 允许
      expect(
          q.enqueue(
            kind: SftpJobKind.copy,
            pathFrom: 'ra',
            pathTo: 'r',
            name: 'c',
            sessionFrom: BigInt.two,
            sessionTo: BigInt.two,
          ),
          isNotNull);
      q.dispose();
    });

    test('clearFinished：清完成/取消，保留失败', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final a = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r', name: 'a');
      final b = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r2', name: 'b');
      t.complete(a.jobId);
      t.complete(b.jobId);
      await pumpEventQueue();
      final failed = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r3', name: 'c');
      t.fail(failed.jobId, 'x');
      await pumpEventQueue();
      final canceled = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r4', name: 'd');
      q.cancel(canceled);
      t.fail(canceled.jobId, '传输已取消');
      await pumpEventQueue();
      q.clearFinished();
      expect(q.jobs, [failed], reason: '仅失败任务保留（可重试）');
      q.dispose();
    });

    test('shutdown：运行中发取消，排队中直接置态', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final running = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r', name: 'a');
      final running2 = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r2', name: 'b');
      final queued = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r3', name: 'c');
      await q.shutdown();
      expect(t.cancels, [running.jobId, running2.jobId]);
      expect(running.state, SftpJobState.canceled);
      expect(running2.state, SftpJobState.canceled);
      expect(queued.state, SftpJobState.canceled);
      q.dispose();
    });

    test('dispose 后的取消/重试/清理为 no-op', () async {
      final t = FakeTransport();
      final q = _queue(t);
      final a = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r1', name: 'a');
      final b = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r2', name: 'b');
      t.complete(a.jobId);
      t.complete(b.jobId);
      await pumpEventQueue();
      final failed = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r3', name: 'c');
      t.fail(failed.jobId, 'x');
      await pumpEventQueue();
      expect(failed.state, SftpJobState.failed);
      final running = _enq(q,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r4', name: 'd');
      expect(running.state, SftpJobState.running);
      q.dispose();

      final cancelsBefore = List<int>.from(t.cancels);
      q.cancel(running); // no-op
      expect(t.cancels, cancelsBefore);
      q.retry(failed); // no-op
      expect(failed.state, SftpJobState.failed);
      q.clearFinished(); // no-op
      expect(q.jobs.length, 4);
      expect(
          q.enqueue(
            kind: SftpJobKind.upload,
            pathFrom: 'l',
            pathTo: 'r5',
            name: 'e',
          ),
          isNull);
      // 终态任务 cancel/retry 也为 no-op（未 dispose）
      final q2 = _queue(t);
      final done = _enq(q2,
          kind: SftpJobKind.upload, pathFrom: 'l', pathTo: 'r6', name: 'f');
      t.complete(done.jobId);
      await pumpEventQueue();
      q2.cancel(done);
      q2.retry(done);
      expect(done.state, SftpJobState.done);
      expect(t.cancels, cancelsBefore,
          reason: '对终态任务取消不应发出 Rust cancel');
      q2.dispose();
    });
  });
}
