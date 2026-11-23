// SFTP 双侧文件管理页 v2（任务清单 #6/#7/#8/#9）：
// - 两侧各自为「远端会话」或「本机工作区」，任选两台服务器互传，不再限制一边是本地
// - 桌面双栏：按住文件拖到对侧面板，松手传到对侧当前目录（与 ⋮ 菜单同一条 _transfer）
// - 远端目录 → 本地：exec tar -czf - 打包压缩流式下载（<名>.tar.gz）
// - 远端目录 → 远端：递归逐文件复制（目标同大小跳过，重试可续）
// - 远端文件 → 远端：分块经客户端内存直传（B 侧 .eterm-part 暂存 + 改名）
// - 传输队列跨会话（任务自带会话 id）；任务完成自动刷新目标侧列表（目标目录在浏览中时）
// 传输暂存：<目标>.eterm-part（Rust api/sftp.rs），取消/失败保留 → 重试续传。

import 'dart:async';
import 'dart:io';

import 'package:eterm/services/sftp_transfer_queue.dart';
import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:eterm/src/rust/api/sftp.dart' as sftp;
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_state.dart';
import 'sftp_drag.dart';
import 'sftp_edit_page.dart';
import 'theme.dart';
import 'ui_utils.dart';

/// 一侧的规格：host == null 表示本机工作区。
class SftpSideSpec {
  const SftpSideSpec({this.host, this.authKind, this.secret});
  final HostView? host;
  final String? authKind; // password | key
  final String? secret;
}

enum _SidePhase { localPending, localReady, connecting, live, failed }

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

/// 一侧的运行状态。
class _Side {
  _Side(this.spec);
  final SftpSideSpec spec;

  bool get isLocal => spec.host == null;
  String get label => isLocal ? '本机' : (spec.host!.label);

  _SidePhase phase = _SidePhase.connecting;
  String? reason; // 连接失败原因

  BigInt? sessionId;
  String rpath = '/';
  List<sftp.SftpEntry>? rentries; // null = 列表加载中
  int listSeq = 0; // 在途列举序号：慢响应不得覆盖新目录的结果（导航/自动刷新并发）

  // 本地浏览（远端侧恒为 null；桌面初始 localPending 等待选目录）
  String? lpath;
  String? lroot;
  bool rootFixed = false;
  List<_LocalEntry>? lentries;
  int localListSeq = 0;
}

class SftpDualPage extends StatefulWidget {
  const SftpDualPage({super.key, required this.left, required this.right});

  final SftpSideSpec left;
  final SftpSideSpec right;

  @override
  State<SftpDualPage> createState() => _SftpDualPageState();
}

class _SftpDualPageState extends State<SftpDualPage> {
  late final _Side _l = _Side(widget.left);
  late final _Side _r = _Side(widget.right);
  late final List<_Side> _sides = [_l, _r];

  final SftpTransferQueue _queue = SftpTransferQueue();

  /// 任务完成后的自动刷新登记：job → (侧下标, 目标目录)（任务清单 #9）。
  /// 以任务对象为键（identity）：retry 换 jobId 后同一实例仍能接住完成事件。
  final Map<SftpTransferJob, (int, String)> _autoRefresh = {};

  bool _busy = false; // mkdir/rename/delete 等快速写操作
  int _activeSide = 0; // 手机布局：当前展示哪侧

  @override
  void initState() {
    super.initState();
    for (final s in _sides) {
      if (s.isLocal) {
        s.phase = _SidePhase.localPending;
        _initLocal(s);
      } else {
        _connect(s);
      }
    }
    _queue.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueueChanged);
    unawaited(_queue.shutdown());
    _queue.dispose();
    for (final s in _sides) {
      final id = s.sessionId;
      if (id != null) {
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
      }
    }
    super.dispose();
  }

  // ---------- 连接与浏览 ----------

  Future<void> _connect(_Side s) async {
    final h = s.spec.host!;
    setState(() {
      s.phase = _SidePhase.connecting;
      s.reason = null;
    });
    BigInt? id;
    try {
      id = await sftp.sftpConnect(
        host: h.hostname,
        port: h.port,
        user: h.username,
        authKind: s.spec.authKind!,
        secret: s.spec.secret!,
      );
      final real = await sftp.sftpRealpath(id: id, path: '.');
      if (!mounted) {
        sftp.sftpDisconnect(id: id);
        return;
      }
      final liveId = id; // 闭包内空安全提升失效：先取局部非空副本
      setState(() {
        s.sessionId = liveId;
        s.phase = _SidePhase.live;
        s.rpath = real.isEmpty ? '/' : real;
      });
      await _list(s);
    } catch (e) {
      if (id != null) sftp.sftpDisconnect(id: id);
      if (!mounted) return;
      setState(() {
        s.phase = _SidePhase.failed;
        s.reason = '$e';
      });
    }
  }

  Future<void> _list(_Side s) async {
    final id = s.sessionId;
    if (id == null) return;
    final seq = ++s.listSeq;
    setState(() => s.rentries = null);
    try {
      final items = await sftp.sftpList(id: id, path: s.rpath);
      if (!mounted || seq != s.listSeq) return; // 已发起更新的列举
      setState(() => s.rentries = items);
    } catch (e) {
      if (!mounted || seq != s.listSeq) return;
      setState(() => s.rentries = []);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取目录失败: $e')));
    }
  }

  String _joinRemote(_Side s, String name) =>
      s.rpath.endsWith('/') ? '${s.rpath}$name' : '${s.rpath}/$name';

  void _enterRemote(_Side s, sftp.SftpEntry e) {
    setState(() => s.rpath = _joinRemote(s, e.name));
    _list(s);
  }

  void _upRemote(_Side s) {
    if (s.rpath == '/' || s.rpath.isEmpty) return;
    final idx = s.rpath.lastIndexOf('/');
    setState(() => s.rpath = idx <= 0 ? '/' : s.rpath.substring(0, idx));
    _list(s);
  }

  Set<String> _remoteNames(_Side s) =>
      (s.rentries ?? const []).map((e) => e.name).toSet();

  Future<void> _initLocal(_Side s) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        // Android：应用专属外部目录（免权限、系统文件管理器可见）；
        // iOS：应用沙箱 Documents（免权限、经 UIFileSharingEnabled 对
        // 「文件」App 与 Finder 可见）——两端同构落盘（方案 §4.4 / D6）
        final base = Platform.isAndroid
            ? (await getExternalStorageDirectory())?.path ??
                  (await getApplicationDocumentsDirectory()).path
            : (await getApplicationDocumentsDirectory()).path;
        final ws = Directory('$base/sftp-local');
        await ws.create(recursive: true);
        if (!mounted) return;
        setState(() {
          s.lroot = ws.path;
          s.lpath = ws.path;
          s.rootFixed = true;
          s.phase = _SidePhase.localReady;
        });
        _lsLocal(s);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          s.phase = _SidePhase.failed;
          s.reason = '初始化本机目录失败: $e';
        });
      }
      return;
    }
    // 桌面：恢复上次选择的目录（评审 P1：此前每次打开都要重选）
    try {
      final saved = local.kvGet(key: 'sftp.localRoot');
      if (saved.isNotEmpty && Directory(saved).existsSync()) {
        if (!mounted) return;
        setState(() {
          s.lroot = saved;
          s.lpath = saved;
          s.phase = _SidePhase.localReady;
        });
        _lsLocal(s);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => s.phase = _SidePhase.localPending);
  }

  Future<void> _pickLocalRoot(_Side s) async {
    try {
      final dir = await getDirectoryPath();
      if (dir == null || !mounted) return;
      try {
        local.kvPut(key: 'sftp.localRoot', value: dir);
      } catch (_) {}
      setState(() {
        s.lroot = dir;
        s.lpath = dir;
        s.lentries = null;
        s.phase = _SidePhase.localReady;
      });
      _lsLocal(s);
    } catch (e) {
      _err('选择目录失败: $e');
    }
  }

  Future<void> _lsLocal(_Side s) async {
    final dir = s.lpath;
    if (dir == null) return;
    final seq = ++s.localListSeq;
    try {
      final out = <_LocalEntry>[];
      await for (final entity in Directory(dir).list(followLinks: false)) {
        final st = await entity.stat();
        out.add(
          _LocalEntry(
            name: entity.path.split('/').last,
            isDir: st.type == FileSystemEntityType.directory,
            size: st.size,
            mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      }
      out.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted || seq != s.localListSeq) return; // 已发起更新的列举
      setState(() => s.lentries = out);
    } catch (e) {
      if (!mounted || seq != s.localListSeq) return;
      setState(() => s.lentries = []);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取本地目录失败: $e')));
    }
  }

  String? _joinLocal(_Side s, String name) {
    final dir = s.lpath;
    if (dir == null) return null;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  void _enterLocal(_Side s, _LocalEntry e) {
    final p = _joinLocal(s, e.name);
    if (p == null) return;
    setState(() {
      s.lpath = p;
      s.lentries = null;
    });
    _lsLocal(s);
  }

  void _upLocal(_Side s) {
    final dir = s.lpath;
    if (dir == null || s.lroot == null || dir == s.lroot) {
      return; // 已在浏览根（Android 工作区 / macOS 所选目录，沙盒外不可浏览）
    }
    final idx = dir.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : dir.substring(0, idx);
    if (parent == dir) return;
    setState(() {
      s.lpath = parent;
      s.lentries = null;
    });
    _lsLocal(s);
  }

  Set<String> _localNames(_Side s) =>
      (s.lentries ?? const []).map((e) => e.name).toSet();

  // ---------- 传输（任务清单 #7/#8） ----------

  _Side _otherOf(_Side s) => identical(s, _l) ? _r : _l;

  int _indexOf(_Side s) => identical(s, _l) ? 0 : 1;

  /// 文件行可拖时包一层识别器。不可拖（手机单栏、对侧还不能收、本机目录）原样返回。
  Widget _maybeDrag({
    required bool enabled,
    required _Side src,
    required String name,
    required bool isDir,
    sftp.SftpEntry? remote,
    _LocalEntry? local,
    required Widget Function() buildRow,
  }) {
    final row = buildRow();
    if (!enabled) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: SftpPanelDraggable<_SftpDrag>(
        data: _SftpDrag(
          sideIndex: _indexOf(src),
          name: name,
          isDir: isDir,
          remote: remote,
          local: local,
        ),
        feedback: _DragChip(name: name, isDir: isDir),
        childWhenDragging: Opacity(opacity: 0.38, child: buildRow()),
        child: row,
      ),
    );
  }

  /// 整侧都是落点：松手传到该侧当前目录，不看落在哪一行上。
  Widget _dropPanel(_Side s, {required Widget child}) {
    final index = _indexOf(s);
    return DragTarget<_SftpDrag>(
      onWillAcceptWithDetails: (d) => d.data.sideIndex != index,
      onAcceptWithDetails: (d) {
        unawaited(
          _transfer(
            _sides[d.data.sideIndex],
            re: d.data.remote,
            le: d.data.local,
          ),
        );
      },
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (hot)
              const Positioned.fill(
                child: IgnorePointer(child: _DropHighlight()),
              ),
          ],
        );
      },
    );
  }

  /// 从 src 侧把条目传到对侧。按两侧类型分派：
  ///   文件：本地→远端 upload；远端→本地 download；远端→远端 copy
  ///   目录：远端→本地 tarDownload（<名>.tar.gz）；远端→远端 copyDir 递归复制
  Future<void> _transfer(
    _Side src, {
    sftp.SftpEntry? re,
    _LocalEntry? le,
  }) async {
    final dst = _otherOf(src);
    final name = re?.name ?? le!.name;
    final isDir = re?.isDir ?? le!.isDir;

    // 源侧路径
    String? pathFrom;
    BigInt? sessionFrom;
    SftpRemoteSpec? specFrom;
    if (src.isLocal) {
      pathFrom = _joinLocal(src, name);
      if (pathFrom == null) {
        _err('请先选择本机目录');
        return;
      }
    } else {
      pathFrom = _joinRemote(src, name);
      sessionFrom = src.sessionId;
      specFrom = _specOf(src);
    }

    if (isDir && src.isLocal) {
      _err('目录上传暂不支持；请在对侧创建目录后逐文件传输');
      return;
    }

    // 目标侧路径 + 冲突检查
    String pathTo;
    if (dst.isLocal) {
      if (dst.lpath == null) {
        // iOS 同走固定目录自愈（getDirectoryPath 在 iOS 未实现，兜底进 _pickLocalRoot
        // 必抛 MissingPluginException 成死路——review P1#3）
        if (Platform.isAndroid || Platform.isIOS) {
          await _initLocal(dst);
        } else {
          await _pickLocalRoot(dst);
        }
        if (dst.lpath == null) {
          _err('请先在对侧选择本机目录');
          return;
        }
      }
      final localName = (!src.isLocal && isDir) ? '$name.tar.gz' : name;
      pathTo = _joinLocal(dst, localName)!;
      final conflict =
          File(pathTo).existsSync() || Directory(pathTo).existsSync();
      if (conflict) {
        final act = await _conflictDialog(localName);
        if (act == null || act == ConflictAction.skip) return;
        if (act == ConflictAction.rename) {
          pathTo = _joinLocal(
            dst,
            nextAvailableName(_localNames(dst), localName),
          )!;
        }
      }
    } else {
      if (dst.sessionId == null) {
        _err('对侧尚未连接完成');
        return;
      }
      if (dst.sessionId == src.sessionId) {
        _err('源与目标为同一会话，无传输意义');
        return;
      }
      pathTo = _joinRemote(dst, name);
      if (_remoteNames(dst).contains(name)) {
        if (isDir) {
          final ok = await _confirmMerge(name);
          if (ok != true) return; // 合并复制：已存在目录跳过同大小文件续传
        } else {
          final act = await _conflictDialog(name);
          if (act == null || act == ConflictAction.skip) return;
          if (act == ConflictAction.rename) {
            pathTo = _joinRemote(
              dst,
              nextAvailableName(_remoteNames(dst), name),
            );
          }
        }
      }
    }

    final SftpJobKind kind;
    BigInt? sessionTo;
    if (src.isLocal) {
      kind = SftpJobKind.upload;
      sessionTo = dst.sessionId;
    } else if (dst.isLocal) {
      kind = isDir ? SftpJobKind.tarDownload : SftpJobKind.download;
    } else {
      kind = isDir ? SftpJobKind.copyDir : SftpJobKind.copy;
      sessionTo = dst.sessionId;
    }
    final displayName = (!src.isLocal && isDir && dst.isLocal)
        ? '$name.tar.gz'
        : name;

    final job = _queue.enqueue(
      kind: kind,
      pathFrom: pathFrom,
      pathTo: pathTo,
      name: displayName,
      sessionFrom: sessionFrom,
      sessionTo: sessionTo,
      specFrom: specFrom,
    );
    if (job == null) {
      _err('该目标已在传输队列中');
      return;
    }
    _registerAutoRefresh(job, dst);
  }

  SftpRemoteSpec _specOf(_Side s) => SftpRemoteSpec(
    host: s.spec.host!.hostname,
    port: s.spec.host!.port,
    user: s.spec.host!.username,
    authKind: s.spec.authKind!,
    secret: s.spec.secret!,
  );

  /// 任务清单 #9：入队时登记「完成后刷新目标侧列表」。
  /// 目标侧：upload/copy/copyDir = 远端目标侧；download/tarDownload = 本机目标侧。
  void _registerAutoRefresh(SftpTransferJob job, _Side dst) {
    final path = job.targetPath;
    final idx = _indexOf(dst);
    final dir = dst.isLocal ? _localParentOf(path) : _remoteParentOf(path);
    _autoRefresh[job] = (idx, dir);
  }

  String _remoteParentOf(String path) {
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  String _localParentOf(String path) {
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  /// 队列状态变化：任务完成 → 若目标侧正浏览目标目录则刷新（任务清单 #9）。
  void _onQueueChanged() {
    if (_autoRefresh.isEmpty) return;
    final settled = <SftpTransferJob>[];
    for (final e in _autoRefresh.entries) {
      final job = e.key; // 同一实例：retry 换 jobId 后仍有效
      if (job.state == SftpJobState.done) {
        final (sideIdx, dir) = e.value;
        final s = _sides[sideIdx];
        final current = s.isLocal ? (s.lpath ?? '') : s.rpath;
        if (current == dir) {
          if (s.isLocal) {
            _lsLocal(s);
          } else {
            _list(s);
          }
        }
        settled.add(job);
      } else if (job.isTerminal) {
        settled.add(job); // 失败/取消：清理登记
      }
    }
    if (settled.isNotEmpty) {
      setState(() {
        for (final k in settled) {
          _autoRefresh.remove(k);
        }
      });
    }
  }

  // ---------- 远端编辑与写操作 ----------

  Future<void> _editRemote(_Side s, sftp.SftpEntry e) async {
    final id = s.sessionId;
    if (id == null || e.isDir) return;
    if (e.size.toInt() > 2 * 1024 * 1024) {
      _err('文件超过 2MB，暂不支持编辑');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpEditPage(
          hostLabel: s.spec.host!.label,
          sessionId: id,
          remotePath: _joinRemote(s, e.name),
        ),
      ),
    );
    if (mounted) _list(s);
  }

  Future<void> _mkdir(_Side s) async {
    final name = await _promptText(s.isLocal ? '新建文件夹（本机）' : '新建文件夹', '文件夹名称');
    if (name == null || name.isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (s.isLocal) {
        await Directory(_joinLocal(s, name)!).create(recursive: true);
        await _lsLocal(s);
      } else {
        await sftp.sftpMkdir(id: s.sessionId!, path: _joinRemote(s, name));
        await _list(s);
      }
    } catch (e) {
      _err('创建失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(_Side s, {sftp.SftpEntry? re, _LocalEntry? le}) async {
    final name = re?.name ?? le!.name;
    final isDir = re?.isDir ?? le!.isDir;
    final newName = await _promptText('重命名', '新名称', initial: name);
    if (newName == null || newName.isEmpty || newName == name) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (s.isLocal) {
        final from = _joinLocal(s, name)!;
        final to = _joinLocal(s, newName)!;
        if (isDir) {
          await Directory(from).rename(to);
        } else {
          await File(from).rename(to);
        }
        await _lsLocal(s);
      } else {
        await sftp.sftpRename(
          id: s.sessionId!,
          from: _joinRemote(s, name),
          to: _joinRemote(s, newName),
        );
        await _list(s);
      }
    } catch (e) {
      _err('重命名失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(_Side s, {sftp.SftpEntry? re, _LocalEntry? le}) async {
    final name = re?.name ?? le!.name;
    final isDir = re?.isDir ?? le!.isDir;
    final ok = await _confirmDelete(name, isDir, remote: !s.isLocal);
    if (ok != true) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (s.isLocal) {
        final p = _joinLocal(s, name)!;
        if (isDir) {
          await Directory(p).delete(); // 仅空目录（rmdir 语义）
        } else {
          await File(p).delete();
        }
        await _lsLocal(s);
      } else {
        if (isDir) {
          await sftp.sftpRmdir(id: s.sessionId!, path: _joinRemote(s, name));
        } else {
          await sftp.sftpRemove(id: s.sessionId!, path: _joinRemote(s, name));
        }
        await _list(s);
      }
    } catch (e) {
      _err('删除失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 通用 UI ----------

  Future<ConflictAction?> _conflictDialog(String name) {
    return showDialog<ConflictAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '「$name」已存在',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: Text(
          '目标侧已有同名条目，如何处理？',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Et.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ConflictAction.skip),
            child: Text('跳过', style: TextStyle(color: Et.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ConflictAction.rename),
            child: Text('自动改名', style: TextStyle(color: Et.textPrimary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ConflictAction.overwrite),
            style: FilledButton.styleFrom(
              backgroundColor: Et.danger,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmMerge(String name) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '目录「$name」已存在',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: Text(
          '将合并复制：已存在且同大小的文件跳过，其余覆盖。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Et.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: Et.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Et.primaryBtn,
              foregroundColor: Et.primaryBtnText,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: const Text('合并复制'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmDelete(
    String name,
    bool isDir, {
    required bool remote,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '删除',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: Text(
          remote
              ? (isDir ? '删除远端空目录「$name」？（目录须为空）' : '删除远端文件「$name」？不可恢复。')
              : (isDir ? '删除本机空目录「$name」？（目录须为空）' : '删除本机文件「$name」？不可恢复。'),
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Et.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: Et.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Et.danger,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: const Text('删除'),
          ),
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
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: Et.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: Et.primaryBtn,
              foregroundColor: Et.primaryBtnText,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _openQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ListenableBuilder(
        listenable: _queue,
        builder: (context, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '传输队列',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: Et.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_queue.activeCount} 个进行中',
                        style: TextStyle(fontSize: 12, color: Et.textSecondary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _queue.clearFinished,
                        child: Text('清已完成', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Et.cardBorder),
                Expanded(child: _queueList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueList() {
    if (_queue.jobs.isEmpty) {
      return Center(
        child: Text(
          '暂无传输任务',
          style: TextStyle(fontSize: 13, color: Et.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _queue.jobs.length,
      itemBuilder: (context, i) {
        final j = _queue.jobs[_queue.jobs.length - 1 - i]; // 最新在上
        return _QueueRow(
          job: j,
          onCancel: () => _queue.cancel(j),
          onRetry: () => _queue.retry(j),
        );
      },
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    final compact = MediaQuery.sizeOf(context).width < 720;
    final macGap = !compact && Platform.isMacOS;
    final title = '${_l.label} ⇄ ${_r.label}';
    return Scaffold(
      backgroundColor: Et.contentBg,
      appBar: AppBar(
        // macOS 隐藏标题栏窗口：默认 leading 会压在交通灯下，
        // 左移让位（+48 保证 BackButton 完整命中区，复审可选项 1）
        leadingWidth: macGap ? kMacTitleBarInset + 48 : null,
        leading: macGap
            ? const Padding(
                padding: EdgeInsets.only(left: kMacTitleBarInset),
                child: BackButton(),
              )
            : null,
        backgroundColor: Et.card,
        surfaceTintColor: Et.card,
        elevation: 0.5,
        foregroundColor: Et.textPrimary,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              compact
                  ? _sideSubtitle(_activeSide == 0 ? _l : _r)
                  // Menlo 无 ⇄ 字形会回退成 #（复审可选项 3），分隔符用 ·；
                  // 方向语义由上方标题的 ⇄ 承载
                  : '${_sideSubtitle(_l)}  ·  ${_sideSubtitle(_r)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Menlo',
                color: Et.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: _queue,
            builder: (context, _) {
              final n = _queue.activeCount;
              return IconButton(
                onPressed: _openQueue,
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
            listenable: _queue,
            builder: (context, _) {
              SftpTransferJob? job;
              for (final j in _queue.jobs) {
                if (j.state == SftpJobState.running) {
                  job = j;
                  break;
                }
              }
              if (job == null) return const SizedBox(height: 3);
              final total = job.total;
              return LinearProgressIndicator(
                value: total > 0 ? job.transferred / total : null,
                minHeight: 3,
                color: Et.accent,
                backgroundColor: Et.cardBorder,
              );
            },
          ),
        ),
      ),
      body: compact
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(
                          _l.isLocal ? Icons.phone_android : Icons.dns_outlined,
                          size: 17,
                        ),
                        label: Text(_l.label),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(
                          _r.isLocal ? Icons.phone_android : Icons.dns_outlined,
                          size: 17,
                        ),
                        label: Text(_r.label),
                      ),
                    ],
                    selected: {_activeSide},
                    onSelectionChanged: (s) =>
                        setState(() => _activeSide = s.first),
                  ),
                ),
                Expanded(
                  child: _sideBody(
                    _activeSide == 0 ? _l : _r,
                    dragEnabled: false,
                  ),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _dropPanel(
                    _l,
                    child: _sideBody(_l, dragEnabled: true),
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: Et.cardBorder),
                Expanded(
                  child: _dropPanel(
                    _r,
                    child: _sideBody(_r, dragEnabled: true),
                  ),
                ),
              ],
            ),
    );
  }

  String _sideSubtitle(_Side s) => s.isLocal
      ? (s.lpath ?? '本机未选择目录')
      : '${s.spec.host!.username}@${s.spec.host!.hostname}:${s.rpath}';

  Widget _sideBody(_Side s, {required bool dragEnabled}) {
    if (!s.isLocal && s.phase == _SidePhase.connecting) {
      return _note('连接 ${s.label} 中…', spinner: true);
    }
    if (!s.isLocal && s.phase == _SidePhase.failed) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              s.reason ?? '连接失败',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Et.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _connect(s),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
              backgroundColor: Et.primaryBtn,
              foregroundColor: Et.primaryBtnText,
            ),
          ),
        ],
      );
    }
    if (s.isLocal && s.phase == _SidePhase.localPending) {
      // 桌面：等待选择目录（Android 由 _initLocal 直接就绪）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '选择一个本机目录开始浏览',
              style: TextStyle(fontSize: 13, color: Et.textSecondary),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _pickLocalRoot(s),
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('选择目录'),
              style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        _panelHeader(s),
        Divider(height: 1, color: Et.cardBorder),
        Expanded(
          child: s.isLocal
              ? _localList(s, dragEnabled: dragEnabled)
              : _remoteList(s, dragEnabled: dragEnabled),
        ),
      ],
    );
  }

  Widget _panelHeader(_Side s) {
    final picked = !s.isLocal || s.lpath != null;
    final path = s.isLocal ? (picked ? s.lpath! : '未选择目录') : s.rpath;
    return Container(
      color: Et.card,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(
            s.isLocal ? Icons.phone_android : Icons.dns,
            size: 15,
            color: Et.textSecondary,
          ),
          const SizedBox(width: 6),
          Text(
            s.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Et.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'Menlo',
                color: Et.textSecondary,
              ),
            ),
          ),
          if (s.isLocal && !s.rootFixed)
            IconButton(
              onPressed: () => _pickLocalRoot(s),
              tooltip: '选择本机目录',
              icon: Icon(Icons.folder_open, size: 19, color: Et.textSecondary),
            ),
          IconButton(
            onPressed: () => s.isLocal ? _lsLocal(s) : _list(s),
            tooltip: '刷新',
            icon: Icon(Icons.refresh, size: 19, color: Et.textSecondary),
          ),
          IconButton(
            onPressed: _busy ? null : () => _mkdir(s),
            tooltip: s.isLocal ? '新建文件夹（本机）' : '新建文件夹（远端）',
            icon: Icon(
              Icons.create_new_folder_outlined,
              size: 19,
              color: Et.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _remoteList(_Side s, {required bool dragEnabled}) {
    final entries = s.rentries;
    if (entries == null) return _note('读取目录中…', spinner: true);
    // 与本地列表同规则排序：目录在前，名称不区分大小写（评审 P2）
    final sorted = [...entries]
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    if (sorted.isEmpty) {
      return s.rpath == '/' || s.rpath.isEmpty
          ? _note('空目录')
          : ListView(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.arrow_upward,
                    size: 20,
                    color: Et.textSecondary,
                  ),
                  title: const Text(
                    '..',
                    style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5),
                  ),
                  onTap: () => _upRemote(s),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: _note('空目录'),
                ),
              ],
            );
    }
    final canUp = s.rpath != '/' && s.rpath.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
      itemCount: entries.length + (canUp ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && canUp) {
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.arrow_upward,
              size: 20,
              color: Et.textSecondary,
            ),
            title: const Text(
              '..',
              style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5),
            ),
            onTap: () => _upRemote(s),
          );
        }
        final e = sorted[i - (canUp ? 1 : 0)];
        final other = _otherOf(s);
        final canTransfer =
            other.isLocal ||
            (other.sessionId != null && other.sessionId != s.sessionId);
        final otherLabel = other.isLocal ? '本机' : other.label;
        return _maybeDrag(
          enabled: dragEnabled && canTransfer,
          src: s,
          name: e.name,
          isDir: e.isDir,
          remote: e,
          buildRow: () => _FileRow(
            name: e.name,
            isDir: e.isDir,
            meta: [
              if (!e.isDir) _fmtSize(e.size.toInt()),
              _fmtTime(e.mtime),
            ].join(' · '),
            onOpen: e.isDir ? () => _enterRemote(s, e) : null,
            actions: [
              if (canTransfer)
                _RowAction(
                  label: e.isDir
                      ? (other.isLocal
                            ? '打包下载到本机（.tar.gz）'
                            : '复制到 $otherLabel（递归）')
                      : (other.isLocal ? '下载到本机' : '直传到 $otherLabel'),
                  icon: e.isDir ? Icons.folder_zip_outlined : Icons.swap_horiz,
                  onTap: () => _transfer(s, re: e),
                ),
              if (!e.isDir)
                _RowAction(
                  label: '编辑',
                  icon: Icons.edit_outlined,
                  onTap: () => _editRemote(s, e),
                ),
              _RowAction(
                label: '重命名',
                icon: Icons.drive_file_rename_outline,
                onTap: () => _rename(s, re: e),
              ),
              _RowAction(
                label: '删除',
                icon: Icons.delete_outline,
                destructive: true,
                onTap: () => _delete(s, re: e),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _localList(_Side s, {required bool dragEnabled}) {
    final entries = s.lentries;
    if (s.lpath == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '先选择一个本机目录',
              style: TextStyle(fontSize: 13, color: Et.textSecondary),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _pickLocalRoot(s),
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('选择目录'),
              style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
              ),
            ),
          ],
        ),
      );
    }
    if (entries == null) return _note('读取目录中…', spinner: true);
    // 与远端列表对称：空目录给占位（复审可选项 2）
    if (entries.isEmpty) {
      return s.lroot != null && s.lpath != s.lroot
          ? ListView(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.arrow_upward,
                    size: 20,
                    color: Et.textSecondary,
                  ),
                  title: const Text(
                    '..',
                    style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5),
                  ),
                  onTap: () => _upLocal(s),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: _note('空目录'),
                ),
              ],
            )
          : _note('空目录');
    }
    final canUp = s.lroot != null && s.lpath != s.lroot; // 浏览根不提供上级
    final other = _otherOf(s);
    final canUpload = !other.isLocal && other.sessionId != null;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
      itemCount: entries.length + (canUp ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && canUp) {
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.arrow_upward,
              size: 20,
              color: Et.textSecondary,
            ),
            title: const Text(
              '..',
              style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5),
            ),
            onTap: () => _upLocal(s),
          );
        }
        final e = entries[i - (canUp ? 1 : 0)];
        return _maybeDrag(
          enabled: dragEnabled && !e.isDir && canUpload,
          src: s,
          name: e.name,
          isDir: e.isDir,
          local: e,
          buildRow: () => _FileRow(
            name: e.name,
            isDir: e.isDir,
            meta: [
              if (!e.isDir) _fmtSize(e.size),
              _fmtTime(e.mtime),
            ].join(' · '),
            onOpen: e.isDir ? () => _enterLocal(s, e) : null,
            actions: [
              if (!e.isDir && canUpload)
                _RowAction(
                  label: '上传到 ${other.label}',
                  icon: Icons.upload_outlined,
                  onTap: () => _transfer(s, le: e),
                ),
              _RowAction(
                label: '重命名',
                icon: Icons.drive_file_rename_outline,
                onTap: () => _rename(s, le: e),
              ),
              _RowAction(
                label: '删除',
                icon: Icons.delete_outline,
                destructive: true,
                onTap: () => _delete(s, le: e),
              ),
            ],
          ),
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
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (spinner) const SizedBox(height: 10),
        Text(text, style: TextStyle(fontSize: 13, color: Et.textSecondary)),
      ],
    ),
  );
}

/// 拖放载荷：哪一侧的哪一条。落点只认 sideIndex，路径由 _transfer 按对侧当前目录算。
class _SftpDrag {
  _SftpDrag({
    required this.sideIndex,
    required this.name,
    required this.isDir,
    this.remote,
    this.local,
  }) : assert(remote != null || local != null);

  final int sideIndex;
  final String name;
  final bool isDir;
  final sftp.SftpEntry? remote;
  final _LocalEntry? local;
}

/// 跟手的文件名芯片。左上角锚在指针上，再往右下偏一点，避免挡住落点。
class _DragChip extends StatelessWidget {
  const _DragChip({required this.name, required this.isDir});

  final String name;
  final bool isDir;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(14, 16),
      child: Material(
        color: Et.card,
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Et.accent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDir
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
                size: 16,
                color: isDir ? Et.tileGroup : Et.textSecondary,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 12.5,
                    color: Et.textPrimary,
                    decoration: TextDecoration.none,
                    decorationColor: Et.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropHighlight extends StatelessWidget {
  const _DropHighlight();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Et.accent.withValues(alpha: 0.12),
        border: Border.all(color: Et.accent, width: 2),
      ),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Et.accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '松手传到当前目录',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Et.primaryBtnText,
            ),
          ),
        ),
      ),
    );
  }
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
        color: isDir ? Et.tileGroup : Et.textSecondary,
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Menlo',
          fontSize: 13.5,
          fontWeight: isDir ? FontWeight.w600 : FontWeight.w400,
          color: Et.textPrimary,
        ),
      ),
      subtitle: Text(
        meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: Et.textSecondary),
      ),
      trailing: PopupMenuButton<int>(
        color: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        icon: Icon(Icons.more_vert, size: 19, color: Et.textSecondary),
        onSelected: (v) => actions[v].onTap(),
        itemBuilder: (_) => [
          for (var i = 0; i < actions.length; i++)
            PopupMenuItem(
              value: i,
              height: 40,
              child: Row(
                children: [
                  Icon(
                    actions[i].icon,
                    size: 17,
                    color: actions[i].destructive
                        ? Et.danger
                        : Et.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    actions[i].label,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: actions[i].destructive
                          ? Et.danger
                          : Et.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      onTap: onOpen,
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.job,
    required this.onCancel,
    required this.onRetry,
  });

  final SftpTransferJob job;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (job.state) {
      (SftpJobState.queued) => ('排队中', Et.textSecondary, Icons.hourglass_empty),
      (SftpJobState.running) => ('传输中', Et.tileGroup, Icons.sync),
      (SftpJobState.done) => (
        '完成',
        Color(0xFF1A7F37),
        Icons.check_circle_outline,
      ),
      (SftpJobState.failed) => ('失败', Et.danger, Icons.error_outline),
      (SftpJobState.canceled) => (
        '已取消',
        Et.textSecondary,
        Icons.cancel_outlined,
      ),
    };
    final kindLabel = switch (job.kind) {
      SftpJobKind.upload => '上传',
      SftpJobKind.download => '下载',
      SftpJobKind.copy => '直传',
      SftpJobKind.tarDownload => '打包',
      SftpJobKind.copyDir => '目录复制',
    };
    final total = job.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (job.kind) {
                  SftpJobKind.upload => Icons.upload_outlined,
                  SftpJobKind.download => Icons.download_outlined,
                  SftpJobKind.copy => Icons.swap_horiz,
                  SftpJobKind.tarDownload => Icons.folder_zip_outlined,
                  SftpJobKind.copyDir => Icons.folder_copy_outlined,
                },
                size: 16,
                color: Et.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                kindLabel,
                style: TextStyle(fontSize: 11.5, color: Et.textSecondary),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  job.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 13,
                    color: Et.textPrimary,
                  ),
                ),
              ),
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: color)),
              if (!job.isTerminal)
                IconButton(
                  onPressed: onCancel,
                  tooltip: '取消',
                  icon: Icon(Icons.close, size: 18, color: Et.textSecondary),
                )
              else if (job.state == SftpJobState.failed ||
                  job.state == SftpJobState.canceled)
                IconButton(
                  onPressed: onRetry,
                  tooltip: job.kind == SftpJobKind.tarDownload
                      ? '重试（重新打包）'
                      : job.kind == SftpJobKind.copyDir
                      ? '重试（跳过已完成文件）'
                      : '重试（断点续传）',
                  icon: Icon(Icons.refresh, size: 18, color: Et.tileGroup),
                ),
            ],
          ),
          // 源 → 目标路径上下文（评审 P2：此前队列行看不出传往哪侧）
          Tooltip(
            message: '${job.pathFrom} → ${job.pathTo}',
            child: Text(
              '${job.pathFrom} → ${job.pathTo}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'Menlo',
                color: Et.textSecondary,
              ),
            ),
          ),
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
              style: TextStyle(fontSize: 11, color: Et.textSecondary),
            ),
          ],
          if (job.error != null && job.state == SftpJobState.failed)
            Text(
              job.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Et.danger),
            ),
        ],
      ),
    );
  }
}
