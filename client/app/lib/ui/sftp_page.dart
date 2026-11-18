// SFTP 双面板文件管理页（M3）：远端 = SFTP 会话（数据面直连目标主机，不经中枢）；
// 本地 = 沙盒可浏览目录（macOS 用户选定目录 / Android 应用专属外部目录工作区）。
// 传输经 SftpTransferQueue 后台执行（并发 2、可取消、断点续传、失败重试），
// 冲突策略（跳过/覆盖/改名）在入队前弹窗决策；传输进度不阻塞浏览。
// 传输暂存：<目标>.eterm-part（Rust api/sftp.rs），取消/失败保留 → 重试续传。

import 'dart:async';
import 'dart:io';

import 'package:eterm/services/sftp_transfer_queue.dart';
import 'package:eterm/src/rust/api/sftp.dart' as sftp;
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_state.dart';
import 'sftp_edit_page.dart';
import 'theme.dart';

class SftpPage extends StatefulWidget {
  const SftpPage({
    super.key,
    required this.host,
    required this.authKind,
    required this.secret,
  });

  final HostView host;
  final String authKind; // password | key
  final String secret;

  @override
  State<SftpPage> createState() => _SftpPageState();
}

enum _Phase { connecting, live, failed }

String _fmtSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}G';
}

String _fmtTime(int unixSecs) {
  final t = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm';
}

/// 本地目录项（与远端 SftpEntry 对齐展示字段）。
class _LocalEntry {
  const _LocalEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.mtime,
  });
  final String name;
  final bool isDir;
  final int size;
  final int mtime;
}

class _SftpPageState extends State<SftpPage> {
  BigInt? _id;
  _Phase _phase = _Phase.connecting;
  String? _reason;

  // 远端面板
  String _rpath = '/';
  List<sftp.SftpEntry>? _rentries; // null = 列表加载中

  // 本地面板（_lpath == null = macOS 尚未选择目录）
  String? _lpath;
  /// 本地浏览根：Android = 固定工作区；macOS = 用户所选目录（沙盒授权子树，根之上不可达）。
  String? _lroot;
  bool _lrootFixed = false; // Android 工作区固定，不提供“选择目录”
  List<_LocalEntry>? _lentries;

  // 传输队列与写操作互斥
  SftpTransferQueue? _queue;
  bool _busy = false; // mkdir/rename/delete 等快速写操作（传输不占用）
  bool _localActive = false; // 手机布局：当前展示哪一侧

  @override
  void initState() {
    super.initState();
    _connect();
    _initLocal();
  }

  @override
  void dispose() {
    final q = _queue;
    _queue = null;
    if (q != null) {
      unawaited(q.shutdown());
      q.dispose();
    }
    final id = _id;
    if (id != null) {
      try {
        sftp.sftpDisconnect(id: id);
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _phase = _Phase.connecting;
      _reason = null;
    });
    BigInt? id;
    try {
      id = await sftp.sftpConnect(
        host: widget.host.hostname,
        port: widget.host.port,
        user: widget.host.username,
        authKind: widget.authKind,
        secret: widget.secret,
      );
      final real = await sftp.sftpRealpath(id: id, path: '.');
      if (!mounted) {
        // 页面已退出（_id 尚未赋值，dispose 管不到）：显式释放，否则会话泄漏
        sftp.sftpDisconnect(id: id);
        return;
      }
      final liveId = id; // 闭包内空安全提升失效：先取局部非空副本
      setState(() {
        _id = liveId;
        _phase = _Phase.live;
        _rpath = real.isEmpty ? '/' : real;
        _queue = SftpTransferQueue(sessionId: liveId);
      });
      await _list();
    } catch (e) {
      // 连接成功但 realpath/列表失败：同样释放，避免泄漏（幂等）
      if (id != null) sftp.sftpDisconnect(id: id);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _reason = '$e';
      });
    }
  }

  // ---------- 远端浏览 ----------

  Future<void> _list() async {
    final id = _id;
    if (id == null) return;
    setState(() => _rentries = null);
    try {
      final items = await sftp.sftpList(id: id, path: _rpath);
      if (!mounted) return;
      setState(() => _rentries = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _rentries = []);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取目录失败: $e')));
    }
  }

  String _joinRemote(String name) =>
      _rpath.endsWith('/') ? '$_rpath$name' : '$_rpath/$name';

  void _enterRemote(sftp.SftpEntry e) {
    setState(() => _rpath = _joinRemote(e.name));
    _list();
  }

  void _upRemote() {
    if (_rpath == '/' || _rpath.isEmpty) return;
    final idx = _rpath.lastIndexOf('/');
    setState(() => _rpath = idx <= 0 ? '/' : _rpath.substring(0, idx));
    _list();
  }

  Set<String> get _remoteNames =>
      (_rentries ?? const []).map((e) => e.name).toSet();

  // ---------- 本地浏览 ----------

  Future<void> _initLocal() async {
    if (!Platform.isAndroid) return; // 桌面：等用户选目录
    // Android：应用专属外部目录（免权限、系统文件管理器可见），无需 SAF 目录树
    final ext = await getExternalStorageDirectory();
    final base =
        ext?.path ?? (await getApplicationDocumentsDirectory()).path;
    final ws = Directory('$base/sftp-local');
    await ws.create(recursive: true);
    _lroot = ws.path;
    _lpath = ws.path;
    _lrootFixed = true;
    _lsLocal();
  }

  Future<void> _pickLocalRoot() async {
    try {
      final dir = await getDirectoryPath();
      if (dir == null) return;
      setState(() {
        _lroot = dir;
        _lpath = dir;
        _lentries = null;
      });
      _lsLocal();
    } catch (e) {
      _err('选择目录失败: $e');
    }
  }

  Future<void> _lsLocal() async {
    final dir = _lpath;
    if (dir == null) return;
    try {
      final out = <_LocalEntry>[];
      await for (final entity
          in Directory(dir).list(followLinks: false)) {
        final st = await entity.stat();
        out.add(_LocalEntry(
          name: entity.path.split('/').last,
          isDir: st.type == FileSystemEntityType.directory,
          size: st.size,
          mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
        ));
      }
      out.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() => _lentries = out);
    } catch (e) {
      if (!mounted) return;
      setState(() => _lentries = []);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取本地目录失败: $e')));
    }
  }

  String? _joinLocal(String name) {
    final dir = _lpath;
    if (dir == null) return null;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  void _enterLocal(_LocalEntry e) {
    final p = _joinLocal(e.name);
    if (p == null) return;
    setState(() {
      _lpath = p;
      _lentries = null;
    });
    _lsLocal();
  }

  void _upLocal() {
    final dir = _lpath;
    if (dir == null || _lroot == null || dir == _lroot) {
      return; // 已在浏览根（Android 工作区 / macOS 所选目录，沙盒外不可浏览）
    }
    final idx = dir.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : dir.substring(0, idx);
    if (parent == dir) return;
    setState(() {
      _lpath = parent;
      _lentries = null;
    });
    _lsLocal();
  }

  Set<String> get _localNames =>
      (_lentries ?? const []).map((e) => e.name).toSet();

  // ---------- 冲突决策 ----------

  /// 同名冲突弹窗：null（关闭）与 skip 同义。
  Future<ConflictAction?> _conflictDialog(String name) {
    return showDialog<ConflictAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('「$name」已存在',
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: const Text('目标侧已有同名文件，如何处理？',
            style: TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, ConflictAction.skip),
              child: const Text('跳过',
                  style: TextStyle(color: Et.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ConflictAction.rename),
              child: const Text('自动改名',
                  style: TextStyle(color: Et.textPrimary))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ConflictAction.overwrite),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD1242F),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('覆盖')),
        ],
      ),
    );
  }

  // ---------- 传输入口 ----------

  /// 本地 → 远端（本地面板行操作）。
  Future<void> _uploadEntry(_LocalEntry e) async {
    final id = _id;
    final q = _queue;
    if (id == null || q == null || e.isDir || _busy) return;
    final localPath = _joinLocal(e.name);
    if (localPath == null) return;
    String target = e.name;
    try {
      final st =
          await sftp.sftpStat(id: id, path: _joinRemote(e.name));
      if (st != null) {
        final act = await _conflictDialog(e.name);
        if (act == null || act == ConflictAction.skip) return;
        if (act == ConflictAction.rename) {
          target = nextAvailableName(_remoteNames, e.name);
        }
      }
    } catch (err) {
      _err('检查远端文件失败: $err');
      return;
    }
    if (q.enqueue(
      direction: SftpDirection.upload,
      localPath: localPath,
      remotePath: _joinRemote(target),
      name: target,
    ) == null) {
      _err('该文件已在传输队列中');
    }
  }

  /// 系统“选取文件”快捷上传（SAF/NSSavePanel，任意位置）→ 远端当前目录。
  Future<void> _uploadPicked() async {
    final id = _id;
    final q = _queue;
    if (id == null || q == null || _busy) return;
    final XFile? file = await openFile();
    if (file == null || !mounted) return;
    final name = file.name;
    String target = name;
    try {
      final st = await sftp.sftpStat(id: id, path: _joinRemote(name));
      if (st != null) {
        final act = await _conflictDialog(name);
        if (act == null || act == ConflictAction.skip) return;
        if (act == ConflictAction.rename) {
          target = nextAvailableName(_remoteNames, name);
        }
      }
    } catch (err) {
      _err('检查远端文件失败: $err');
      return;
    }
    if (q.enqueue(
      direction: SftpDirection.upload,
      localPath: file.path,
      remotePath: _joinRemote(target),
      name: target,
    ) == null) {
      _err('该文件已在传输队列中');
    }
  }

  /// 远端 → 本地当前目录。
  Future<void> _downloadEntry(sftp.SftpEntry e) async {
    final q = _queue;
    if (q == null || e.isDir || _busy) return;
    if (_lpath == null) {
      if (Platform.isAndroid) {
        await _initLocal();
      } else {
        await _pickLocalRoot();
      }
      if (_lpath == null) {
        _err('请先选择本地目录');
        return;
      }
    }
    final localPath = _joinLocal(e.name)!;
    String targetLocal = e.name;
    final conflict = File(localPath).existsSync() ||
        Directory(localPath).existsSync();
    if (conflict) {
      final act = await _conflictDialog(e.name);
      if (act == null || act == ConflictAction.skip) return;
      if (act == ConflictAction.rename) {
        targetLocal = nextAvailableName(_localNames, e.name);
      }
    }
    if (q.enqueue(
      direction: SftpDirection.download,
      remotePath: _joinRemote(e.name),
      localPath: _joinLocal(targetLocal)!,
      name: targetLocal,
    ) == null) {
      _err('该文件已在传输队列中');
    }
  }

  // ---------- 远端编辑 ----------

  Future<void> _editRemote(sftp.SftpEntry e) async {
    final id = _id;
    if (id == null || e.isDir) return;
    if (e.size.toInt() > 2 * 1024 * 1024) {
      _err('文件超过 2MB，暂不支持编辑');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SftpEditPage(
        hostLabel: widget.host.label,
        sessionId: id,
        remotePath: _joinRemote(e.name),
      ),
    ));
    if (mounted) _list(); // 回传可能改变了远端
  }

  // ---------- 远端写操作 ----------

  Future<void> _mkdirRemote() async {
    final name = await _promptText('新建文件夹', '文件夹名称');
    if (name == null || name.isEmpty) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await sftp.sftpMkdir(id: id, path: _joinRemote(name));
      await _list();
    } catch (e) {
      _err('创建失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameRemote(sftp.SftpEntry e) async {
    final name = await _promptText('重命名', '新名称', initial: e.name);
    if (name == null || name.isEmpty || name == e.name) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await sftp.sftpRename(id: id, from: _joinRemote(e.name), to: _joinRemote(name));
      await _list();
    } catch (e2) {
      _err('重命名失败: $e2');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteRemote(sftp.SftpEntry e) async {
    final ok = await _confirmDelete(e.name, e.isDir, remote: true);
    if (ok != true) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (e.isDir) {
        await sftp.sftpRmdir(id: id, path: _joinRemote(e.name));
      } else {
        await sftp.sftpRemove(id: id, path: _joinRemote(e.name));
      }
      await _list();
    } catch (e2) {
      _err('删除失败: $e2');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 本地写操作 ----------

  Future<void> _mkdirLocal() async {
    final dir = _lpath;
    if (dir == null) {
      _err('请先选择本地目录');
      return;
    }
    final name = await _promptText('新建文件夹（本地）', '文件夹名称');
    if (name == null || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      await Directory(_joinLocal(name)!).create(recursive: true);
      await _lsLocal();
    } catch (e) {
      _err('创建失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteLocal(_LocalEntry e) async {
    final ok = await _confirmDelete(e.name, e.isDir, remote: false);
    if (ok != true) return;
    final p = _joinLocal(e.name);
    if (p == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (e.isDir) {
        await Directory(p).delete(); // 仅空目录（rmdir 语义）
      } else {
        await File(p).delete();
      }
      await _lsLocal();
    } catch (e2) {
      _err('删除失败: $e2');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 通用 ----------

  Future<bool?> _confirmDelete(String name, bool isDir,
      {required bool remote}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            remote
                ? (isDir
                    ? '删除远端空目录「$name」？（目录须为空）'
                    : '删除远端文件「$name」？不可恢复。')
                : (isDir
                    ? '删除本地空目录「$name」？（目录须为空）'
                    : '删除本地文件「$name」？不可恢复。'),
            style: const TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD1242F),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('删除')),
        ],
      ),
    );
  }

  void _err(String msg) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _promptText(String title, String label, {String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.primaryBtn,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('确定')),
        ],
      ),
    );
  }

  void _openQueue() {
    final q = _queue;
    if (q == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => ListenableBuilder(
        listenable: q,
        builder: (context, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                  child: Row(children: [
                    const Text('传输队列',
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: Et.textPrimary)),
                    const SizedBox(width: 8),
                    Text('${q.activeCount} 个进行中',
                        style: const TextStyle(
                            fontSize: 12, color: Et.textSecondary)),
                    const Spacer(),
                    TextButton(
                        onPressed: q.clearFinished,
                        child: const Text('清已完成',
                            style: TextStyle(fontSize: 13))),
                  ]),
                ),
                const Divider(height: 1, color: Et.cardBorder),
                Expanded(child: _queueList(q)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueList(SftpTransferQueue q) {
    if (q.jobs.isEmpty) {
      return const Center(
          child: Text('暂无传输任务',
              style: TextStyle(fontSize: 13, color: Et.textSecondary)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: q.jobs.length,
      itemBuilder: (context, i) {
        final j = q.jobs[q.jobs.length - 1 - i]; // 最新在上
        return _QueueRow(
          job: j,
          onCancel: () => q.cancel(j),
          onRetry: () => q.retry(j),
        );
      },
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Scaffold(
      backgroundColor: Et.contentBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Et.textPrimary,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.host.label,
                style: const TextStyle(
                    fontSize: 16.5, fontWeight: FontWeight.w600)),
            Text(compact
                ? (_localActive ? (_lpath ?? '本地') : _rpath)
                : '$_rpath · 本地 ${_lpath ?? "未选择"}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    color: Et.textSecondary)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: (_phase == _Phase.live && !_busy) ? _uploadPicked : null,
            tooltip: '上传文件（系统选取）',
            icon: const Icon(Icons.upload_file_outlined, size: 21),
          ),
          IconButton(
            onPressed:
                (_phase == _Phase.live && !_busy) ? _mkdirRemote : null,
            tooltip: '新建文件夹（远端）',
            icon: const Icon(Icons.create_new_folder_outlined, size: 21),
          ),
          ListenableBuilder(
            listenable: _queue ?? _neverListenable,
            builder: (context, _) {
              final n = _queue?.activeCount ?? 0;
              return IconButton(
                onPressed: _phase == _Phase.live ? _openQueue : null,
                tooltip: '传输队列',
                icon: Badge(
                  isLabelVisible: n > 0,
                  label: Text('$n'),
                  backgroundColor: Et.accent,
                  child: const Icon(Icons.swap_vert, size: 21),
                ),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: ListenableBuilder(
            listenable: _queue ?? _neverListenable,
            builder: (context, _) {
              final q = _queue;
              SftpTransferJob? job;
              if (q != null) {
                for (final j in q.jobs) {
                  if (j.state == SftpJobState.running) {
                    job = j;
                    break;
                  }
                }
              }
              if (job == null) return const SizedBox(height: 3);
              final total = job.total;
              return Column(children: [
                LinearProgressIndicator(
                  value: total > 0 ? job.transferred / total : null,
                  minHeight: 3,
                  color: Et.accent,
                  backgroundColor: Et.cardBorder,
                ),
              ]);
            },
          ),
        ),
      ),
      body: switch (_phase) {
        _Phase.connecting => _note('连接中…', spinner: true),
        _Phase.failed => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_reason ?? '连接失败',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13, color: Et.textSecondary)),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
                style: FilledButton.styleFrom(
                    backgroundColor: Et.primaryBtn,
                    foregroundColor: Colors.white),
              ),
            ],
          ),
        _Phase.live => compact ? _liveCompact() : _liveWide(),
      },
    );
  }

  Widget _liveWide() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _remotePanel()),
        const VerticalDivider(width: 1, thickness: 1, color: Et.cardBorder),
        Expanded(child: _localPanel()),
      ],
    );
  }

  Widget _liveCompact() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: false,
                icon: Icon(Icons.dns_outlined, size: 17),
                label: Text('远端')),
            ButtonSegment(
                value: true,
                icon: Icon(Icons.phone_android, size: 17),
                label: Text('本地')),
          ],
          selected: {_localActive},
          onSelectionChanged: (s) =>
              setState(() => _localActive = s.first),
        ),
      ),
      Expanded(
          child: _localActive
              ? _localPanel()
              : _remotePanel()),
    ]);
  }

  Widget _panelHeader(
      {required String title,
      required String path,
      required List<Widget> actions}) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(children: [
        Text(title,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: Et.textPrimary)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'Menlo',
                  color: Et.textSecondary)),
        ),
        ...actions,
      ]),
    );
  }

  Widget _remotePanel() {
    return Column(children: [
      _panelHeader(title: '远端', path: _rpath, actions: [
        IconButton(
          onPressed: _list,
          tooltip: '刷新',
          icon: const Icon(Icons.refresh, size: 19, color: Et.textSecondary),
        ),
      ]),
      const Divider(height: 1, color: Et.cardBorder),
      Expanded(child: _remoteList()),
    ]);
  }

  Widget _localPanel() {
    final picked = _lpath != null;
    return Column(children: [
      _panelHeader(
          title: '本地',
          path: picked ? _lpath! : '未选择目录',
          actions: [
            if (!_lrootFixed)
              IconButton(
                onPressed: _pickLocalRoot,
                tooltip: '选择本地目录',
                icon: const Icon(Icons.folder_open, size: 19, color: Et.textSecondary),
              ),
            IconButton(
              onPressed: _mkdirLocal,
              tooltip: '新建文件夹（本地）',
              icon: const Icon(Icons.create_new_folder_outlined,
                  size: 19, color: Et.textSecondary),
            ),
          ]),
      const Divider(height: 1, color: Et.cardBorder),
      Expanded(child: _localList()),
    ]);
  }

  Widget _remoteList() {
    final entries = _rentries;
    if (entries == null) return _note('读取目录中…', spinner: true);
    final canUp = _rpath != '/' && _rpath.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
      itemCount: entries.length + (canUp ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && canUp) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward,
                size: 20, color: Et.textSecondary),
            title: const Text('..',
                style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5)),
            onTap: _upRemote,
          );
        }
        final e = entries[i - (canUp ? 1 : 0)];
        return _FileRow(
          name: e.name,
          isDir: e.isDir,
          meta: [
            if (!e.isDir) _fmtSize(e.size.toInt()),
            _fmtTime(e.mtime),
          ].join(' · '),
          onOpen: e.isDir ? () => _enterRemote(e) : null,
          actions: [
            if (!e.isDir) ...[
              _RowAction(
                  label: '下载到本地', icon: Icons.download_outlined,
                  onTap: () => _downloadEntry(e)),
              _RowAction(
                  label: '编辑', icon: Icons.edit_outlined,
                  onTap: () => _editRemote(e)),
            ],
            _RowAction(
                label: '重命名', icon: Icons.drive_file_rename_outline,
                onTap: () => _renameRemote(e)),
            _RowAction(
                label: '删除', icon: Icons.delete_outline,
                destructive: true,
                onTap: () => _deleteRemote(e)),
          ],
        );
      },
    );
  }

  Widget _localList() {
    final entries = _lentries;
    if (_lpath == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('先选择一个本地目录',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _pickLocalRoot,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('选择目录'),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.primaryBtn,
                  foregroundColor: Colors.white),
            ),
          ],
        ),
      );
    }
    if (entries == null) return _note('读取目录中…', spinner: true);
    final canUp = _lroot != null && _lpath != _lroot; // 浏览根不提供上级
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
      itemCount: entries.length + (canUp ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && canUp) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward,
                size: 20, color: Et.textSecondary),
            title: const Text('..',
                style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5)),
            onTap: _upLocal,
          );
        }
        final e = entries[i - (canUp ? 1 : 0)];
        return _FileRow(
          name: e.name,
          isDir: e.isDir,
          meta: [
            if (!e.isDir) _fmtSize(e.size),
            _fmtTime(e.mtime),
          ].join(' · '),
          onOpen: e.isDir ? () => _enterLocal(e) : null,
          actions: [
            if (!e.isDir)
              _RowAction(
                  label: '上传到远端', icon: Icons.upload_outlined,
                  onTap: () => _uploadEntry(e)),
            _RowAction(
                label: '删除', icon: Icons.delete_outline,
                destructive: true,
                onTap: () => _deleteLocal(e)),
          ],
        );
      },
    );
  }

  Widget _note(String text, {bool spinner = false}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinner)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            if (spinner) const SizedBox(height: 10),
            Text(text,
                style:
                    const TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}

class _RowAction {
  const _RowAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.isDir,
    required this.meta,
    required this.onOpen,
    required this.actions,
  });

  final String name;
  final bool isDir;
  final String meta;
  final VoidCallback? onOpen;
  final List<_RowAction> actions;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        size: 22,
        color: isDir ? const Color(0xFF2C63D9) : Et.textSecondary,
      ),
      title: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 13.5,
              fontWeight: isDir ? FontWeight.w600 : FontWeight.w400,
              color: Et.textPrimary)),
      subtitle: Text(meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: Et.textSecondary)),
      trailing: PopupMenuButton<int>(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        icon: const Icon(Icons.more_vert, size: 19, color: Et.textSecondary),
        onSelected: (v) => actions[v].onTap(),
        itemBuilder: (_) => [
          for (var i = 0; i < actions.length; i++)
            PopupMenuItem(
              value: i,
              height: 40,
              child: Row(children: [
                Icon(actions[i].icon,
                    size: 17,
                    color: actions[i].destructive
                        ? const Color(0xFFD1242F)
                        : Et.textSecondary),
                const SizedBox(width: 8),
                Text(actions[i].label,
                    style: TextStyle(
                        fontSize: 13.5,
                        color: actions[i].destructive
                            ? const Color(0xFFD1242F)
                            : Et.textPrimary)),
              ]),
            ),
        ],
      ),
      onTap: onOpen,
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.job, required this.onCancel, required this.onRetry});

  final SftpTransferJob job;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (job.state) {
      (SftpJobState.queued) => ('排队中', Et.textSecondary, Icons.hourglass_empty),
      (SftpJobState.running) => ('传输中', const Color(0xFF2C63D9), Icons.sync),
      (SftpJobState.done) => ('完成', const Color(0xFF1A7F37), Icons.check_circle_outline),
      (SftpJobState.failed) => ('失败', const Color(0xFFD1242F), Icons.error_outline),
      (SftpJobState.canceled) => ('已取消', Et.textSecondary, Icons.cancel_outlined),
    };
    final total = job.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              job.direction == SftpDirection.upload
                  ? Icons.upload_outlined
                  : Icons.download_outlined,
              size: 16,
              color: Et.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(job.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Menlo', fontSize: 13, color: Et.textPrimary)),
          ),
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: 12, color: color)),
          if (!job.isTerminal)
            IconButton(
              onPressed: onCancel,
              tooltip: '取消',
              icon: const Icon(Icons.close, size: 18, color: Et.textSecondary),
            )
          else if (job.state == SftpJobState.failed ||
              job.state == SftpJobState.canceled)
            IconButton(
              onPressed: onRetry,
              tooltip: '重试（断点续传）',
              icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF2C63D9)),
            ),
        ]),
        if (job.state == SftpJobState.running) ...[
          const SizedBox(height: 2),
          LinearProgressIndicator(
            value: total > 0 ? job.transferred / total : null,
            minHeight: 3,
            color: Et.accent,
            backgroundColor: Et.cardBorder,
          ),
          const SizedBox(height: 2),
          Text(
            total > 0
                ? '${_fmtSize(job.transferred)}/${_fmtSize(total)}'
                : '传输中…',
            style: const TextStyle(fontSize: 11, color: Et.textSecondary),
          ),
        ],
        if (job.error != null && job.state == SftpJobState.failed)
          Text(job.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFFD1242F))),
      ]),
    );
  }
}

/// 占位 Listenable：队列为 null（未连接）时避免 ListenableBuilder 报错。
class _NeverListenable extends ChangeNotifier {}

final _neverListenable = _NeverListenable();
