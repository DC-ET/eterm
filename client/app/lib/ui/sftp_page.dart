// SFTP 双侧文件管理页 v2（任务清单 #6/#7/#8/#9）：
// - 两侧各自为「远端会话」或「本机工作区」，任选两台服务器互传，不再限制一边是本地
// - 桌面双栏：按住文件拖到对侧面板，松手传到对侧当前目录（与 ⋮ 菜单同一条 _transfer）
// - 多选：桌面单击替换 / ⌘(Ctrl) 单击切换 / Shift 连选；手机轻点切换。
//   多选后拖任意选中行 = 整个选区一起传；右键菜单（手机长按）批量下载/上传/删除
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
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'sftp_drag.dart';
import 'sftp_edit_page.dart';
import 'sftp_selection.dart';
import 'theme.dart';
import 'ui_utils.dart';
import 'work_tabs.dart';

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

/// 选中条目（远端/本机二选一）：批量传输与删除的统一入参。
class _SelEntry {
  const _SelEntry.remote(this.remote) : local = null;
  const _SelEntry.local(this.local) : remote = null;

  final sftp.SftpEntry? remote;
  final _LocalEntry? local;

  String get name => remote?.name ?? local!.name;
  bool get isDir => remote?.isDir ?? local!.isDir;
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
  /// 最近一次失效的会话 id：重连失败时 sessionId 被清空，队列仍挂着这个旧 id；
  /// 下次重连成功要用它做 fail/rebind（否则任务永远指向死会话）。
  BigInt? staleSessionId;
  String rpath = '/';
  List<sftp.SftpEntry>? rentries; // null = 列表加载中
  int listSeq = 0; // 在途列举序号：慢响应不得覆盖新目录的结果（导航/自动刷新并发）
  int connectSeq = 0; // 连接/重连代次：迟到的连接结果不得覆盖新连接
  bool probeSuspect = false; // 探活失败、尚未确认重连：status 显示 degraded
  bool liveAtPause = false; // 退后台时是否 live（回前台只探活当时活着的侧）
  bool probing = false; // 探活去重：聚焦/恢复可能连续触发
  bool probeAutoReconnect = false; // degraded 后传输 settle 时：自动重连还是判死

  // 本地浏览（远端侧恒为 null；桌面初始 localPending 等待选目录）
  String? lpath;
  String? lroot;
  bool rootFixed = false;
  List<_LocalEntry>? lentries;
  int localListSeq = 0;
  String? localHint; // localPending 时的补充说明（如授权失效需重选）
  // 当前选区（按目录内唯一命名；换目录/刷新即清空，见各导航函数）
  SftpSelection selection = SftpSelection.empty;
}

/// SFTP 双侧工作区。
///
/// 两种承载形态（方案 §4.2）：
/// - [embedded] = true：作为 Shell 的标签内嵌，不自己搭 Scaffold/AppBar，
///   顶部一条细工具条提供队列入口；隐藏时 State 仍存活（TickerMode 停动画）。
/// - [embedded] = false：独立路由页（[SftpDualPage] 包装），保留原 AppBar/返回。
class SftpWorkspace extends StatefulWidget {
  const SftpWorkspace({
    super.key,
    required this.left,
    required this.right,
    this.embedded = true,
    this.visible = true,
    this.status,
  });

  final SftpSideSpec left;
  final SftpSideSpec right;
  final bool embedded;

  /// 是否为当前可见标签：隐藏时业务照常跑，但 SnackBar 延后到切回可见
  /// 再补发（方案 §4.8 / D17）。
  final bool visible;

  /// 标签状态（phase + 传输计数），Shell 的 pill 订阅它。
  final ValueNotifier<WorkTabStatus>? status;

  @override
  State<SftpWorkspace> createState() => _SftpWorkspaceState();
}

/// 独立路由入口（仅兼容旧调用方，新代码请走 Shell.openSftp）。
///
/// 注意：路由形态也会注册到生命周期 registry（移动端回前台同样探活），
/// 但新代码应走 `Shell.openSftp`，才能与终端共享标签栈/关闭确认/状态徽标。
class SftpDualPage extends StatelessWidget {
  const SftpDualPage({super.key, required this.left, required this.right});

  final SftpSideSpec left;
  final SftpSideSpec right;

  @override
  Widget build(BuildContext context) =>
      SftpWorkspace(left: left, right: right, embedded: false);
}

/// 存活的 SFTP 工作区（含隐藏标签）：移动端回前台统一探活/重连（方案 §4.6）。
final Set<_SftpWorkspaceState> _activeSftpWorkspaces = {};

/// 进程回前台：只探活退后台时仍 live 的远端侧（D4）。
void sftpWorkspacesOnAppPaused() {
  for (final w in List.of(_activeSftpWorkspaces)) {
    w._onAppPaused();
  }
}

/// 进程回前台/桌面窗口重新聚焦：探活并重连失联侧（D4/D13）。
void sftpWorkspacesOnAppResume() {
  for (final w in List.of(_activeSftpWorkspaces)) {
    w._onAppResume();
  }
}

/// 桌面窗口聚焦：只探活当前可见的 SFTP 标签（非活动标签省 RTT，D16）。
void sftpWorkspacesProbeVisible() {
  for (final w in List.of(_activeSftpWorkspaces)) {
    if (!w.mounted || !w.widget.visible) continue;
    for (final s in w._sides) {
      if (!s.isLocal && s.phase == _SidePhase.live) {
        unawaited(w._probeOrReconnect(s, reconnect: false));
      }
    }
  }
}

class _SftpWorkspaceState extends State<SftpWorkspace> {
  late final _Side _l = _Side(widget.left);
  late final _Side _r = _Side(widget.right);
  late final List<_Side> _sides = [_l, _r];

  final SftpTransferQueue _queue = SftpTransferQueue();

  /// 任务完成后的自动刷新登记：job → (侧下标, 目标目录)（任务清单 #9）。
  /// 以任务对象为键（identity）：retry 换 jobId 后同一实例仍能接住完成事件。
  final Map<SftpTransferJob, (int, String)> _autoRefresh = {};

  bool _busy = false; // mkdir/rename/delete 等快速写操作
  int _activeSide = 0; // 手机布局：当前展示哪侧
  String? _pendingSnack; // 隐藏期间的提示：切回可见时补发最后一条

  @override
  void initState() {
    super.initState();
    _activeSftpWorkspaces.add(this);
    for (final s in _sides) {
      if (s.isLocal) {
        s.phase = _SidePhase.localPending;
        _initLocal(s);
      } else {
        _connect(s);
      }
    }
    _queue.addListener(_onQueueChanged);
    _publishStatus();
  }

  @override
  void didUpdateWidget(covariant SftpWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      final msg = _pendingSnack;
      _pendingSnack = null;
      if (msg != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.visible) _showSnack(msg);
        });
      }
    }
  }

  @override
  void dispose() {
    _activeSftpWorkspaces.remove(this);
    _queue.removeListener(_onQueueChanged);
    unawaited(_queue.shutdown());
    _queue.dispose();
    for (final s in _sides) {
      final ids = <BigInt>{
        if (s.sessionId != null) s.sessionId!,
        if (s.staleSessionId != null) s.staleSessionId!,
      };
      for (final id in ids) {
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
      }
    }
    super.dispose();
  }

  // ---------- 连接与浏览 ----------

  Future<void> _connect(_Side s) => _connectSide(s, preservePath: false);

  /// 建连/重连统一入口。
  ///
  /// [preservePath] = true 用于断线重连：保持当前远端目录，新会话上重新列举；
  /// 原目录不存在/不可读时回落到主目录（方案 §4.6）。false 用于首次连接与
  /// 用户点「重试」：沿用旧行为回到主目录。
  ///
  /// [connectSeq] 代次防串：并发重连/用户手动重试时，迟到的旧结果直接丢弃并
  /// 关掉它建出来的会话，避免 UI 会话与状态错配。
  Future<void> _connectSide(
    _Side s, {
    required bool preservePath,
  }) async {
    if (s.isLocal) return;
    final h = s.spec.host!;
    final seq = ++s.connectSeq;
    final oldId = s.sessionId;
    if (oldId != null) s.staleSessionId = oldId;
    // 断开旧会话前先挂起队列：旧流报错触发的 _pump 不得拿死 id 启动 queued。
    final rebindId = s.staleSessionId;
    if (rebindId != null) _queue.beginRebind(rebindId);
    setState(() {
      s.phase = _SidePhase.connecting;
      s.reason = null;
      s.probeSuspect = false;
      s.sessionId = null;
      s.listSeq++; // 使在途列举失效，旧会话的列表不得落到新连接上
    });
    _publishStatus();
    if (oldId != null) {
      try {
        sftp.sftpDisconnect(id: oldId);
      } catch (_) {}
    }
    BigInt? id;
    try {
      id = await sftp.sftpConnect(
        host: h.hostname,
        port: h.port,
        user: h.username,
        authKind: s.spec.authKind!,
        secret: s.spec.secret!,
      );
      if (!mounted || seq != s.connectSeq) {
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
        return;
      }
      final real = await sftp.sftpRealpath(id: id, path: '.');
      if (!mounted || seq != s.connectSeq) {
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
        return;
      }
      final liveId = id; // 闭包内空安全提升失效：先取局部非空副本
      final stale = s.staleSessionId;
      setState(() {
        s.sessionId = liveId;
        s.staleSessionId = null;
        s.phase = _SidePhase.live;
        if (!preservePath) s.rpath = real.isEmpty ? '/' : real;
      });
      if (stale != null) {
        // 会话 id 变了：旧任务无法续传（任务自带旧 id），显式失败提示重试；
        // 队列内新任务随后自动落到新会话（D10）。
        _queue.failJobsForSession(stale, reason: '会话已重连，请重试');
        _queue.rebindSession(stale, liveId);
      }
      _publishStatus();
      final ok = await _list(s);
      if (!ok && preservePath && mounted && seq == s.connectSeq) {
        final home = real.isEmpty ? '/' : real;
        if (s.rpath != home) {
          setState(() => s.rpath = home);
          await _list(s);
          _toast('原目录不可用，已回到主目录');
        }
      }
    } catch (e) {
      if (id != null) {
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
      }
      if (!mounted || seq != s.connectSeq) return;
      setState(() {
        s.phase = _SidePhase.failed;
        s.reason = '$e';
        s.rentries = [];
      });
      // 重连失败：没有新会话可绑，旧会话上的排队任务必须停住（不能等 _pump
      // 拿死 id 启动）；成功后 rebind 到新 id，用户再点重试即可续传。
      final stale = s.staleSessionId;
      if (stale != null) {
        _queue.failJobsForSession(
          stale,
          reason: '连接已断开，请重试',
          includeQueued: true,
        );
        _queue.endRebind(stale);
      }
      _publishStatus();
    }
  }

  /// 列举远端目录。返回 false 表示本次列举失败（重连回退主目录要用）。
  Future<bool> _list(_Side s) async {
    final id = s.sessionId;
    if (id == null) return false;
    final seq = ++s.listSeq;
    setState(() {
      s.selection = SftpSelection.empty; // 换目录/刷新：旧选中项已不在列表里
      s.rentries = null;
    });
    try {
      final items = await sftp.sftpList(id: id, path: s.rpath);
      if (!mounted || seq != s.listSeq) return true; // 已发起更新的列举
      final wasSuspect = s.probeSuspect;
      setState(() {
        s.rentries = items;
        s.probeSuspect = false;
      });
      if (wasSuspect) {
        // 列表成功是“会话确实活着”的最强证据：必须释放 degraded 期间的
        // hold，否则该侧 queued 会被永久卡在排队（P1-B 复核新增）。
        s.probeAutoReconnect = false;
        _queue.endRebind(id);
      }
      _publishStatus();
      return true;
    } catch (e) {
      if (!mounted) return false;
      // 被更新的列举取代：本次结果无意义，不能当失败触发回 home（P1-4）
      if (seq != s.listSeq) return true;
      setState(() => s.rentries = []);
      _snack('读取目录失败: $e');
      // 列举失败可能只是目录不存在，也可能是连接已死。异步探活一次：
      // realpath 成功则保持 live，失败才把 phase 置 failed（方案 §4.6）。
      unawaited(_probeAfterListError(s));
      return false;
    }
  }

  Future<void> _probeAfterListError(_Side s) async {
    final id = s.sessionId;
    if (id == null || s.isLocal) return;
    try {
      await sftp.sftpRealpath(
        id: id,
        path: '.',
      ).timeout(const Duration(seconds: 6));
    } catch (_) {
      if (!mounted || s.sessionId != id) return;
      // 大传输占满通道时 realpath 也可能超时：有 running 传输先只降级，
      // 不拆会话/不杀任务（P1-3）；等传输结束后的探活再判死。
      if (_queue.hasRunningForSession(id)) {
        // 通道可能只是忙：先降级并 hold 住 queued；running settle 后
        // _onQueueChanged 会再探一次，成功放行、失败再判死。
        _queue.beginRebind(id);
        s.probeAutoReconnect = false;
        setState(() => s.probeSuspect = true);
        _publishStatus();
        return;
      }
      // 确认已死：断开并清 sessionId 防 UI 继续展示"可传"，旧 id 留给队列重绑。
      s.staleSessionId = id;
      _queue.beginRebind(id);
      try {
        sftp.sftpDisconnect(id: id);
      } catch (_) {}
      setState(() {
        s.phase = _SidePhase.failed;
        s.reason = '连接已断开';
        s.sessionId = null;
        s.rentries = [];
        s.probeSuspect = false;
      });
      _queue.failJobsForSession(
        id,
        reason: '连接已断开，请重试',
        includeQueued: true,
      );
      _queue.endRebind(id);
      _publishStatus();
    }
  }

  // ---------- 生命周期探活（移动端回前台 / 桌面窗口聚焦） ----------

  void _onAppPaused() {
    for (final s in _sides) {
      s.liveAtPause = !s.isLocal && s.phase == _SidePhase.live;
    }
  }

  void _onAppResume() {
    for (final s in _sides) {
      if (!s.isLocal && s.liveAtPause && s.phase == _SidePhase.live) {
        s.liveAtPause = false;
        unawaited(_probeOrReconnect(s, reconnect: true));
      }
    }
  }

  /// 带 6s 超时的探活：真实 socket 操作，进程挂起后冻结的连接会卡住。
  ///
  /// [reconnect] = true（移动端回前台）：确认失联且该会话没有 running 传输时
  /// 自动重连并保留目录；有 running 传输只标 degraded，避免把“通道忙”误判成
  /// 断线（P1-2）。false（桌面窗口聚焦，D16）：只探活，失败标 failed 交给用户
  /// 点重试，不自动新建连接。
  Future<void> _probeOrReconnect(
    _Side s, {
    required bool reconnect,
  }) async {
    final id = s.sessionId;
    if (id == null || s.probing) return;
    s.probing = true;
    try {
      await sftp.sftpRealpath(
        id: id,
        path: '.',
      ).timeout(const Duration(seconds: 6));
      if (!mounted || s.sessionId != id) return;
      if (s.probeSuspect) {
        setState(() => s.probeSuspect = false);
        s.probeAutoReconnect = false;
        _queue.endRebind(id); // 探活恢复：放行 degraded 期间 hold 的 queued
        _publishStatus();
      }
    } catch (_) {
      if (!mounted || s.sessionId != id) return;
      if (_queue.hasRunningForSession(id)) {
        // 传输在跑：探活超时可能只是通道忙，保留会话，仅显示 degraded。
        // hold queued，等 running settle 后由 _onQueueChanged 再探（P1-B）。
        _queue.beginRebind(id);
        s.probeAutoReconnect = reconnect;
        setState(() => s.probeSuspect = true);
        _publishStatus();
        return;
      }
      if (reconnect) {
        setState(() => s.probeSuspect = true);
        _publishStatus();
        await _connectSide(s, preservePath: true);
      } else {
        // 桌面聚焦：判死但不自动重连（用户点重试）。与重连路径同口径清理。
        s.staleSessionId = id;
        _queue.beginRebind(id);
        try {
          sftp.sftpDisconnect(id: id);
        } catch (_) {}
        setState(() {
          s.phase = _SidePhase.failed;
          s.reason = '连接已断开';
          s.sessionId = null;
          s.rentries = [];
          s.probeSuspect = false;
        });
        _queue.failJobsForSession(
          id,
          reason: '连接已断开，请重试',
          includeQueued: true,
        );
        _queue.endRebind(id);
        _publishStatus();
      }
    } finally {
      s.probing = false;
    }
  }

  String _joinRemote(_Side s, String name) =>
      s.rpath.endsWith('/') ? '${s.rpath}$name' : '${s.rpath}/$name';

  void _enterRemote(_Side s, sftp.SftpEntry e) {
    setState(() {
      s.selection = SftpSelection.empty;
      s.rpath = _joinRemote(s, e.name);
    });
    _list(s);
  }

  void _upRemote(_Side s) {
    if (s.rpath == '/' || s.rpath.isEmpty) return;
    final idx = s.rpath.lastIndexOf('/');
    setState(() {
      s.selection = SftpSelection.empty;
      s.rpath = idx <= 0 ? '/' : s.rpath.substring(0, idx);
    });
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
      // 注意：existsSync 会漏放行——沙盒下路径存在 ≠ 可读（授权丢失时 stat 仍成功、
      // 列举才 EPERM），必须真列举一次探活，失败则回退到选目录（见 _localReadable）
      if (saved.isNotEmpty && await _localReadable(saved)) {
        if (!mounted) return;
        setState(() {
          s.localHint = null;
          s.lroot = saved;
          s.lpath = saved;
          s.phase = _SidePhase.localReady;
        });
        _lsLocal(s);
        return;
      }
      if (saved.isNotEmpty && !mounted) return;
      if (saved.isNotEmpty) {
        // 有旧路径但已不可读：几乎总是沙盒授权未跨启动持久化（未存 security-scoped
        // bookmark），给用户一句明白话，别让他对着空列表或报错猜
        setState(() {
          s.localHint = '上次的目录已失去访问授权（macOS 沙盒授权不随重启保留），请重新选择';
        });
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => s.phase = _SidePhase.localPending);
  }

  /// 本地目录可读性探活：真列举一次（空目录也返回 true）。
  /// 沙盒授权失效时 existsSync 为 true 而 list() 抛 PathAccessException，
  /// 只有实际列举才能区分"路径不在"与"存在但没权限"。
  Future<bool> _localReadable(String dir) async {
    try {
      await Directory(dir).list(followLinks: false).take(1).toList();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 是否沙盒/权限类错误（EPERM/EACCES）。此类失败重选目录即可恢复，
  /// 与"目录被删/IO 错"区分开：后者保持空列表+提示，前者回退到选目录状态。
  bool _isPermissionError(Object e) {
    if (e is PathAccessException) return true;
    final msg = e.toString();
    return msg.contains('Operation not permitted') ||
        msg.contains('Permission denied') ||
        msg.contains('errno = 1') ||
        msg.contains('errno = 13') ||
        msg.contains('errno: 1') ||
        msg.contains('errno: 13');
  }

  Future<void> _pickLocalRoot(_Side s) async {
    try {
      final dir = await getDirectoryPath();
      if (dir == null || !mounted) return;
      try {
        local.kvPut(key: 'sftp.localRoot', value: dir);
      } catch (_) {}
      setState(() {
        s.localHint = null;
        s.selection = SftpSelection.empty;
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
    setState(() {
      s.selection = SftpSelection.empty;
      s.lentries = null;
    });
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
      if (_isPermissionError(e)) {
        // 导航进了授权外目录（如 ../ 逃出授权根）：回退到选目录状态，
        // 引导用户重新授权，而不是留一个空列表让人以为目录是空的
        setState(() {
          s.phase = _SidePhase.localPending;
          s.localHint = '无法访问该目录（权限不足），请重新选择';
        });
        _snack('目录需要重新授权');
        return;
      }
      setState(() => s.lentries = []);
      _snack('读取本地目录失败: $e');
    }
  }

  String? _joinLocal(_Side s, String name) {
    final dir = s.lpath;
    if (dir == null) return null;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  /// basename：'/' 与 '' 都归到 '/'（根目录面包屑首段用）。
  String _baseName(String path) {
    if (path.isEmpty || path == '/') return '/';
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  void _enterLocal(_Side s, _LocalEntry e) {
    final p = _joinLocal(s, e.name);
    if (p == null) return;
    setState(() {
      s.selection = SftpSelection.empty;
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
      s.selection = SftpSelection.empty;
      s.lpath = parent;
      s.lentries = null;
    });
    _lsLocal(s);
  }

  /// 面包屑跳转：远端到任意层级（含根）。
  void _jumpRemote(_Side s, String path) {
    final target = path.isEmpty ? '/' : path;
    if (target == s.rpath) return;
    setState(() {
      s.selection = SftpSelection.empty;
      s.rpath = target;
    });
    _list(s);
  }

  /// 面包屑跳转：本机侧钳制在浏览根（授权根）内——逃出去也读不了。
  void _jumpLocal(_Side s, String path) {
    final root = s.lroot;
    if (root == null) return;
    var target = path;
    if (target != root && !target.startsWith('$root/')) target = root;
    if (target == s.lpath) return;
    setState(() {
      s.selection = SftpSelection.empty;
      s.lpath = target;
      s.lentries = null;
    });
    _lsLocal(s);
  }

  /// 远端面包屑分段：['/', 'opt', 'mao-data', ...]；根目录只一段。
  List<String> _remoteCrumbs(_Side s) {
    final p = s.rpath.isEmpty ? '/' : s.rpath;
    if (p == '/') return const ['/'];
    return ['/', ...p.split('/').where((e) => e.isNotEmpty)];
  }

  /// 本机面包屑分段：首段为浏览根（授权根）的 basename，其余为根下的相对层级；
  /// 根之上的路径不可达（沙盒/Android 工作区都不允许），干脆不展示。
  List<String> _localCrumbs(_Side s) {
    final root = s.lroot;
    if (root == null) return const [];
    final path = s.lpath ?? root;
    if (path == root) return [_baseName(root)];
    final rel = path.startsWith('$root/') ? path.substring(root.length + 1) : '';
    return [_baseName(root), ...rel.split('/').where((e) => e.isNotEmpty)];
  }

  /// 由面包屑下标还原完整路径（两端同构：0 = 根/浏览根）。
  String _crumbPath(_Side s, List<String> crumbs, int i) {
    if (s.isLocal) {
      final root = s.lroot ?? '';
      return i <= 0 ? root : '$root/${crumbs.sublist(1, i + 1).join('/')}';
    }
    return i <= 0 ? '/' : '/${crumbs.sublist(1, i + 1).join('/')}';
  }

  // ---------- 传输（任务清单 #7/#8） ----------

  _Side _otherOf(_Side s) => identical(s, _l) ? _r : _l;

  int _indexOf(_Side s) => identical(s, _l) ? 0 : 1;

  /// 文件行可拖时包一层识别器。不可拖（手机单栏、对侧还不能收、本机目录）原样返回。
  /// 载荷记锚点行 + 条目快照；松手时由 [_dragEntries] 解析整选区，
  /// 源侧列表恰好在拖拽期间刷新（选区被清）时退回快照，避免静默丢拖。
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
    // 多选时拖任意选中行 = 整选区；拖未选中行 = 只拖该行（与松手解析同口径）。
    // 本机目录不支持上传，计数只算文件，免反馈芯片报大数。
    var dragCount = 1;
    if (src.selection.contains(name)) {
      if (src.isLocal) {
        final names = src.selection.names;
        dragCount = (src.lentries ?? const <_LocalEntry>[])
            .where((e) => names.contains(e.name) && !e.isDir)
            .length;
        if (dragCount < 1) dragCount = 1;
      } else {
        dragCount = src.selection.length;
      }
    }
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: SftpPanelDraggable<_SftpDrag>(
        data: _SftpDrag(
          sideIndex: _indexOf(src),
          anchorName: name,
          remote: remote,
          local: local,
        ),
        feedback: _DragChip(name: name, isDir: isDir, count: dragCount),
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
        // 多选：锚点在选区内则传整个选区，否则只传锚点行
        final src = _sides[d.data.sideIndex];
        unawaited(_transferBatch(src, _dragEntries(src, d.data)));
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

  /// 从 src 侧把单条传到对侧（行 ⋮ 菜单入口，批量逻辑的薄包装）。
  Future<void> _transfer(_Side src, {sftp.SftpEntry? re, _LocalEntry? le}) =>
      _transferBatch(src, [
        if (re != null) _SelEntry.remote(re) else _SelEntry.local(le!),
      ]);

  /// 对侧当前能否接收（本机恒可；远端需已连接且不是同一会话；双本机无意义）。
  bool _canTransfer(_Side src) {
    final dst = _otherOf(src);
    if (src.isLocal && dst.isLocal) return false;
    return dst.isLocal ||
        (dst.sessionId != null && dst.sessionId != src.sessionId);
  }

  /// 选区（按当前列表顺序解析，批量入队顺序与界面一致）。
  List<_SelEntry> _selectedEntries(_Side s) =>
      _entriesNamed(s, s.selection.names);

  List<_SelEntry> _entriesNamed(_Side s, Set<String> names) {
    if (names.isEmpty) return const [];
    if (s.isLocal) {
      return [
        for (final e in s.lentries ?? const <_LocalEntry>[])
          if (names.contains(e.name)) _SelEntry.local(e),
      ];
    }
    return [
      for (final e in _sortedRemote(s.rentries ?? const <sftp.SftpEntry>[]))
        if (names.contains(e.name)) _SelEntry.remote(e),
    ];
  }

  /// 起拖锚点 → 实际传输条目：锚点在选区内则整选区，否则只拖锚点行。
  /// 源侧列表在拖拽期间被刷新（选区已清、列表加载中）时退回载荷快照，
  /// 与旧实现一致：绝不静默丢拖。
  List<_SelEntry> _dragEntries(_Side src, _SftpDrag drag) {
    final names = src.selection.dragNames(drag.anchorName, _orderedNames(src));
    final entries = _entriesNamed(src, names.toSet());
    if (entries.isNotEmpty) return entries;
    if (drag.remote != null) return [_SelEntry.remote(drag.remote!)];
    if (drag.local != null) return [_SelEntry.local(drag.local!)];
    return const [];
  }

  /// 界面展示顺序（远端：目录在前、名称不区分大小写；本机列表已在 _lsLocal 排好）。
  List<String> _orderedNames(_Side s) => s.isLocal
      ? [for (final e in s.lentries ?? const <_LocalEntry>[]) e.name]
      : [for (final e in _sortedRemote(s.rentries ?? const [])) e.name];

  List<sftp.SftpEntry> _sortedRemote(List<sftp.SftpEntry> entries) {
    final sorted = [...entries];
    sorted.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  /// 本机目标名是否已被文件或目录占用。
  bool _localExists(_Side dst, String name) {
    final p = _joinLocal(dst, name);
    if (p == null) return false;
    return File(p).existsSync() || Directory(p).existsSync();
  }

  /// 批量传输：同一侧选中的条目逐条入队。按两侧类型分派：
  ///   文件：本地→远端 upload；远端→本地 download；远端→远端 copy
  ///   目录：远端→本地 tarDownload（<名>.tar.gz）；远端→远端 copyDir 递归复制
  /// - 目标同名冲突整批决策一次：跳过冲突项 / 全部覆盖 / 冲突项自动改名
  /// - 远端→远端目录已存在：合并复制确认一次
  /// - 本机目录不支持上传（跳过并提示；远端目录可打包下载/递归复制）
  /// - 目标已在队列中的条目由队列去重，最后汇总提示
  Future<void> _transferBatch(_Side src, List<_SelEntry> items) async {
    if (items.isEmpty) return;
    final dst = _otherOf(src);
    if (src.isLocal && dst.isLocal) {
      _toast('两侧都是本机，无传输意义');
      return;
    }

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
          _toast('请先在对侧选择本机目录');
          return;
        }
      }
    } else {
      if (dst.sessionId == null) {
        _toast('对侧尚未连接完成');
        return;
      }
      if (dst.sessionId == src.sessionId) {
        _toast('源与目标为同一会话，无传输意义');
        return;
      }
      // 目标目录列表未加载完（刚连接/刚切目录）：此时按空列表判冲突会把同名文件
      // 静默覆盖，宁可让用户稍后再拖
      if (dst.rentries == null) {
        _toast('对侧目录仍在读取中，请稍后再试');
        return;
      }
    }
    if (!src.isLocal && src.sessionId == null) {
      _toast('源侧连接已断开');
      return;
    }
    if (!mounted) return;

    // 本机目录上传暂不支持
    var skippedDirs = 0;
    final sending = <_SelEntry>[];
    for (final e in items) {
      if (e.isDir && src.isLocal) {
        skippedDirs++;
      } else {
        sending.add(e);
      }
    }
    if (skippedDirs > 0) {
      _toast('目录上传暂不支持，已跳过 $skippedDirs 个目录');
    }
    if (sending.isEmpty) return;

    // 远端目录打包到本机时目标名带 .tar.gz
    String targetNameOf(_SelEntry e) =>
        (!src.isLocal && e.isDir && dst.isLocal) ? '${e.name}.tar.gz' : e.name;

    final existing = dst.isLocal ? <String>{} : _remoteNames(dst);
    final conflicts = <_SelEntry>[];
    final reserved = <String>{};
    for (final e in sending) {
      final n = targetNameOf(e);
      final taken =
          reserved.contains(n) ||
          existing.contains(n) ||
          (dst.isLocal && _localExists(dst, n));
      if (taken) {
        conflicts.add(e);
      } else {
        reserved.add(n);
      }
    }

    ConflictAction? policy;
    if (conflicts.isNotEmpty) {
      final act = await _conflictDialogBatch(conflicts.length);
      if (!mounted) return;
      if (act == null) return; // 取消：整批不传
      policy = act;
      if (act == ConflictAction.skip) {
        sending.removeWhere(conflicts.contains);
        if (sending.isEmpty) return;
      }
    }

    // 远端→远端目录已存在且选择覆盖：目录不可"覆盖"，只能合并复制，
    // 确认一次（已存在且同大小的文件跳过，其余覆盖）
    if (!src.isLocal && !dst.isLocal && policy == ConflictAction.overwrite) {
      final merging = [
        for (final e in sending)
          if (e.isDir && existing.contains(targetNameOf(e))) e,
      ];
      if (merging.isNotEmpty) {
        final ok = await _confirmMerge(
          merging.first.name,
          count: merging.length,
        );
        if (!mounted) return;
        if (ok != true) {
          sending.removeWhere(merging.contains);
          if (sending.isEmpty) return;
        }
      }
    }

    // 弹窗/选目录期间连接可能掉线：入队前再校验一次，
    // 否则 FrbSftpTransport 的 sessionId! 会在任务启动时空断言
    if (!src.isLocal && src.sessionId == null) {
      _toast('源侧连接已断开，传输已取消');
      return;
    }
    if (!dst.isLocal && dst.sessionId == null) {
      _toast('对侧连接已断开，传输已取消');
      return;
    }

    final allocated = <String>{...reserved};
    var duplicated = 0;
    for (final e in sending) {
      var name = targetNameOf(e);
      if (policy == ConflictAction.rename && conflicts.contains(e)) {
        final taken = {...existing, ...allocated};
        name = dst.isLocal
            ? allocateUniqueName(
                name,
                taken: taken,
                exists: (n) => _localExists(dst, n),
              )
            : allocateUniqueName(name, taken: taken);
      }
      allocated.add(name);

      final String pathFrom;
      final BigInt? sessionFrom;
      final SftpRemoteSpec? specFrom;
      if (src.isLocal) {
        pathFrom = _joinLocal(src, e.name)!;
        sessionFrom = null;
        specFrom = null;
      } else {
        pathFrom = _joinRemote(src, e.name);
        sessionFrom = src.sessionId;
        specFrom = _specOf(src);
      }
      final pathTo = dst.isLocal
          ? _joinLocal(dst, name)!
          : _joinRemote(dst, name);

      final SftpJobKind kind;
      BigInt? sessionTo;
      if (src.isLocal) {
        kind = SftpJobKind.upload;
        sessionTo = dst.sessionId;
      } else if (dst.isLocal) {
        kind = e.isDir ? SftpJobKind.tarDownload : SftpJobKind.download;
      } else {
        kind = e.isDir ? SftpJobKind.copyDir : SftpJobKind.copy;
        sessionTo = dst.sessionId;
      }

      final job = _queue.enqueue(
        kind: kind,
        pathFrom: pathFrom,
        pathTo: pathTo,
        name: name,
        sessionFrom: sessionFrom,
        sessionTo: sessionTo,
        specFrom: specFrom,
      );
      if (job == null) {
        duplicated++;
        continue;
      }
      _registerAutoRefresh(job, dst);
    }
    if (duplicated > 0) {
      _toast('$duplicated 项已在传输队列中，已跳过');
    }
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
    _autoRefresh[job] = (idx, _parentOf(path));
  }

  /// 目标路径的父目录（目标侧刷新用；本机与远端同一套 `/` 语义）。
  String _parentOf(String path) {
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  /// 队列状态变化：任务完成 → 若目标侧正浏览目标目录则刷新（任务清单 #9）。
  void _onQueueChanged() {
    _publishStatus();
    // 探活降级时队列被 hold；running 传输 settle（完成/失败）后必须再探一次：
    // 成功则 endRebind 放行 queued，失败则重连或判死（避免 queued 泵到死会话）。
    for (final s in _sides) {
      final id = s.sessionId;
      if (s.isLocal || id == null || !s.probeSuspect) continue;
      if (s.phase != _SidePhase.live) continue;
      if (_queue.hasRunningForSession(id)) continue;
      unawaited(_probeOrReconnect(s, reconnect: s.probeAutoReconnect));
    }
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

  // ---------- 多选与右键菜单 ----------

  /// 行点击：桌面单击替换 / Ctrl(⌘) 单击切换 / Shift 连选；手机轻点切换。
  /// 修饰键在回调时刻读取（点击时按下的键才有效）。
  void _tapRow(
    _Side s,
    String name,
    List<String> ordered, {
    required bool touch,
  }) {
    final kb = HardwareKeyboard.instance;
    final mode = sftpSelectModeFor(
      shift: kb.isShiftPressed,
      // macOS 习惯 ⌘，Windows/Linux 习惯 Ctrl；iOS 外接键盘同样用 ⌘
      toggleKey: Platform.isMacOS || Platform.isIOS
          ? kb.isMetaPressed
          : kb.isControlPressed,
      touch: touch,
    );
    setState(() {
      s.selection = s.selection.tap(name: name, ordered: ordered, mode: mode);
    });
  }

  /// 行右键菜单（手机长按走同一入口）。
  /// 右键未选中行：先把选区替换为该行（Finder/资源管理器习惯）；
  /// 右键已选中行：作用于整个选区（多选时给批量动作）。
  Future<void> _showRowMenu(
    _Side s,
    _SelEntry entry,
    Offset globalPosition,
  ) async {
    if (!s.selection.contains(entry.name)) {
      setState(() {
        s.selection = SftpSelection(names: {entry.name}, anchor: entry.name);
      });
    }
    final actions = s.selection.length > 1
        ? _batchActions(s)
        : _rowActions(s, entry);
    actions.add(
      _RowAction(
        label: '取消选择',
        icon: Icons.deselect,
        onTap: () => setState(() => s.selection = SftpSelection.empty),
      ),
    );
    final overlay = Overlay.of(context).context.findRenderObject();
    final size = overlay is RenderBox
        ? overlay.size
        : MediaQuery.sizeOf(context);
    final right = size.width - globalPosition.dx;
    final bottom = size.height - globalPosition.dy;
    final choice = await showMenu<int>(
      context: context,
      color: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        right < 0 ? 0 : right,
        bottom < 0 ? 0 : bottom,
      ),
      items: _menuItems(actions),
    );
    if (!mounted || choice == null) return;
    if (choice < 0 || choice >= actions.length) return;
    actions[choice].onTap();
  }

  /// 单行动作（⋮ 菜单与右键菜单共用）。
  /// 注意：行 ⋮ 始终只作用于本行（控件语义）；多选批量操作走右键/选区操作条。
  List<_RowAction> _rowActions(_Side s, _SelEntry entry) {
    final other = _otherOf(s);
    final otherLabel = other.label;
    if (s.isLocal) {
      final canUpload = !other.isLocal && other.sessionId != null;
      return [
        if (!entry.isDir && canUpload)
          _RowAction(
            label: '上传到 $otherLabel',
            icon: Icons.upload_outlined,
            onTap: () => unawaited(_transfer(s, le: entry.local)),
          ),
        _RowAction(
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
          onTap: () => unawaited(_rename(s, le: entry.local)),
        ),
        _RowAction(
          label: '删除',
          icon: Icons.delete_outline,
          destructive: true,
          onTap: () => unawaited(_delete(s, le: entry.local)),
        ),
      ];
    }
    final e = entry.remote!;
    return [
      if (_canTransfer(s))
        _RowAction(
          label: e.isDir
              ? (other.isLocal ? '打包下载到本机（.tar.gz）' : '复制到 $otherLabel（递归）')
              : (other.isLocal ? '下载到本机' : '直传到 $otherLabel'),
          icon: e.isDir ? Icons.folder_zip_outlined : Icons.swap_horiz,
          onTap: () => unawaited(_transfer(s, re: e)),
        ),
      if (!e.isDir)
        _RowAction(
          label: '编辑',
          icon: Icons.edit_outlined,
          onTap: () => unawaited(_editRemote(s, e)),
        ),
      _RowAction(
        label: '重命名',
        icon: Icons.drive_file_rename_outline,
        onTap: () => unawaited(_rename(s, re: e)),
      ),
      _RowAction(
        label: '删除',
        icon: Icons.delete_outline,
        destructive: true,
        onTap: () => unawaited(_delete(s, re: e)),
      ),
    ];
  }

  /// 多选批量动作（右键菜单/选区操作条共用）。
  List<_RowAction> _batchActions(_Side s) {
    final items = _selectedEntries(s);
    final other = _otherOf(s);
    final transferable = items.where((e) => !(e.isDir && s.isLocal)).length;
    return [
      if (_canTransfer(s) && transferable > 0)
        _RowAction(
          // 本机目录会被跳过：计数按实际可传条目，不按选区大小
          label: '传输 $transferable 项到 ${other.label}',
          icon: Icons.swap_horiz,
          onTap: () => unawaited(_transferBatch(s, items)),
        ),
      _RowAction(
        label: '删除 ${items.length} 项',
        icon: Icons.delete_outline,
        destructive: true,
        onTap: () => unawaited(_deleteItems(s, items)),
      ),
    ];
  }

  /// 选区操作条：选中非空时显示（桌面右键的显式入口，手机批量操作的唯一入口）。
  /// 手机宽度紧：只给图标（tooltip 说明动作）；桌面给文字按钮。
  Widget _selectionBar(_Side s, {required bool compact}) {
    if (s.selection.isEmpty) return const SizedBox.shrink();
    final items = _selectedEntries(s);
    if (items.isEmpty) return const SizedBox.shrink();
    final other = _otherOf(s);
    final transferable = items.where((e) => !(e.isDir && s.isLocal)).length;
    final textStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 34),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Container(
      color: Et.accent.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${items.length} 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Et.textPrimary,
              ),
            ),
          ),
          if (_canTransfer(s) && transferable > 0)
            if (compact)
              IconButton(
                onPressed: () => unawaited(_transferBatch(s, items)),
                tooltip: '传输 $transferable 项到 ${other.label}',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.swap_horiz, size: 19, color: Et.accent),
              )
            else
              TextButton.icon(
                onPressed: () => unawaited(_transferBatch(s, items)),
                style: textStyle,
                icon: const Icon(Icons.swap_horiz, size: 17),
                label: ConstrainedBox(
                  // 主机名可自定义：窄桌面（双栏各 ~359dp）必须截断，
                  // 否则 Row 非 flex 子项直接 RenderFlex 溢出
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    '传到 ${other.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
          if (compact)
            IconButton(
              onPressed: () => unawaited(_deleteItems(s, items)),
              tooltip: '删除 ${items.length} 项',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline, size: 19, color: Et.danger),
            )
          else
            TextButton.icon(
              onPressed: () => unawaited(_deleteItems(s, items)),
              style: textStyle,
              icon: Icon(Icons.delete_outline, size: 17, color: Et.danger),
              label: Text(
                '删除',
                style: TextStyle(fontSize: 12.5, color: Et.danger),
              ),
            ),
          IconButton(
            onPressed: () => setState(() => s.selection = SftpSelection.empty),
            tooltip: '取消选择',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18, color: Et.textSecondary),
          ),
        ],
      ),
    );
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
          // 动态取当前会话：保活标签重连后 sessionId 已换，钉死旧 id 会写失败
          sessionId: () {
            final current = s.sessionId;
            if (current == null) {
              throw StateError('连接已断开，内容仍在编辑框，可复制后重试');
            }
            return current;
          },
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

  Future<void> _delete(_Side s, {sftp.SftpEntry? re, _LocalEntry? le}) =>
      _deleteItems(s, [
        if (re != null) _SelEntry.remote(re) else _SelEntry.local(le!),
      ]);

  /// 批量删除（⋮ 菜单单条删除走同一条路径）。逐条执行并汇总失败：
  /// 目录仅支持空目录（rmdir 语义），非空目录会失败但不影响其余条目。
  Future<void> _deleteItems(_Side s, List<_SelEntry> items) async {
    if (items.isEmpty) return;
    // 写操作互斥在确认前检查：否则用户确认后才因 _busy 静默返回，等于白点
    if (_busy) {
      _toast('有写操作进行中，请稍后再试');
      return;
    }
    final ok = await _confirmDeleteItems(items, remote: !s.isLocal);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final failures = <String>[];
    for (final e in items) {
      try {
        if (s.isLocal) {
          final p = _joinLocal(s, e.name)!;
          if (e.isDir) {
            await Directory(p).delete(); // 仅空目录（rmdir 语义）
          } else {
            await File(p).delete();
          }
        } else {
          if (e.isDir) {
            await sftp.sftpRmdir(
              id: s.sessionId!,
              path: _joinRemote(s, e.name),
            );
          } else {
            await sftp.sftpRemove(
              id: s.sessionId!,
              path: _joinRemote(s, e.name),
            );
          }
        }
      } catch (err) {
        failures.add('${e.name}: $err');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // 一次刷新（`_list`/`_lsLocal` 同时清空选区）
    if (s.isLocal) {
      await _lsLocal(s);
    } else {
      await _list(s);
    }
    if (failures.isNotEmpty && mounted) {
      // 最多列 3 条：批量失败时第一条信息通常不足以定位
      final preview = failures.take(3).join('；');
      final more = failures.length > 3 ? ' 等' : '';
      _err('${failures.length} 项删除失败：$preview$more');
    }
  }

  // ---------- 通用 UI ----------

  /// 批量冲突决策：整批一次（逐条问会刷屏；批量传输时同名项通常成批出现）。
  Future<ConflictAction?> _conflictDialogBatch(int count) {
    return showDialog<ConflictAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '$count 项在目标侧已存在',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: Text(
          '如何处理这些同名条目？',
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
            child: const Text('全部覆盖'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmMerge(String name, {int count = 1}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          count > 1 ? '$count 个目录在目标侧已存在' : '目录「$name」已存在',
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

  Future<bool?> _confirmDeleteItems(
    List<_SelEntry> items, {
    required bool remote,
  }) {
    final who = remote ? '远端' : '本机';
    final count = items.length;
    final String question;
    if (count == 1) {
      final e = items.first;
      question = e.isDir
          ? '删除$who空目录「${e.name}」？（目录须为空）'
          : '删除$who文件「${e.name}」？不可恢复。';
    } else {
      final hasDir = items.any((e) => e.isDir);
      question = '删除$who $count 项？${hasDir ? '（目录须为空，非空目录会失败）' : ''}不可恢复。';
    }
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
          question,
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
    _snack(msg);
  }

  /// 仅提示，不碰 _busy（_err 会解除写互斥，非错误提示不该顺带解除）。
  void _toast(String msg) {
    if (!mounted) return;
    _snack(msg);
  }

  /// 统一提示出口（方案 §4.8）：隐藏标签不弹全局 SnackBar（避免多标签串台），
  /// 但记下最后一条，切回可见时补发，避免后台失败完全无提示。
  void _snack(String msg) {
    if (!mounted) return;
    if (!widget.visible) {
      _pendingSnack = msg;
      return;
    }
    _showSnack(msg);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  /// 发布标签状态：phase 为远端侧聚合，传输计数来自队列。
  /// 只在值变化时写 notifier，避免 Tab 栏频繁重建。
  void _publishStatus() {
    final n = widget.status;
    if (n == null) return;
    final remote = _sides.where((s) => !s.isLocal).toList();
    final live = remote.where((s) => s.phase == _SidePhase.live).length;
    final failed = remote.where((s) => s.phase == _SidePhase.failed).length;
    var phase = aggregateSftpPhase(
      total: remote.length,
      live: live,
      failed: failed,
    );
    if (phase != WorkTabPhase.closed &&
        remote.any((s) => s.probeSuspect)) {
      phase = WorkTabPhase.degraded;
    }
    var active = 0;
    var failedJobs = 0;
    for (final j in _queue.jobs) {
      if (j.state == SftpJobState.failed) failedJobs++;
      if (!j.isTerminal) active++;
    }
    final next = WorkTabStatus(
      phase: phase,
      activeTransfers: active,
      failedTransfers: failedJobs,
    );
    if (n.value != next) n.value = next;
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
    // ⚠️ 勿改回 showModalBottomSheet：底部弹层贴窗口底边，队列长时列表被切在
    // 屏幕外、桌面端无滚动条难以察觉（用户实踩）；与 app 内其他居中弹窗不一致。
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ListenableBuilder(
          listenable: _queue,
          builder: (context, _) => ConstrainedBox(
            // 高度封顶 70% 屏高：队列再长也整体在屏内，超出部分列表内滚动
            constraints: BoxConstraints(
                maxWidth: 520, maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                Flexible(child: _queueList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueList() {
    if (_queue.jobs.isEmpty) {
      return SizedBox(
        height: 140, // 固定高：Center 在 Flexible 里会填满弹窗，空队列时避免大空框
        child: Center(
          child: Text(
            '暂无传输任务',
            style: TextStyle(fontSize: 13, color: Et.textSecondary),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
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
    if (widget.embedded) {
      // 嵌入 Shell 标签：不搭 Scaffold/AppBar（外层 Shell 已有），顶部只留
      // 一条细工具条承载传输队列入口与进度；SafeArea 避开手机状态栏。
      return ColoredBox(
        color: Et.contentBg,
        child: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              _queueProgressLine(),
              // 手机纵向空间紧：队列入口并入 SegmentedButton 行的右侧
              if (!compact) _embeddedToolbar(),
              Expanded(child: _body(compact)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Et.contentBg,
      appBar: _appBar(compact),
      body: _body(compact),
    );
  }

  Widget _embeddedToolbar() {
    final subtitle = '${_sideSubtitle(_l)}  ·  ${_sideSubtitle(_r)}';
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: Et.card,
        border: Border(bottom: BorderSide(color: Et.cardBorder)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Menlo',
                color: Et.textSecondary,
              ),
            ),
          ),
          _queueButton(),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  AppBar _appBar(bool compact) {
    final macGap = !compact && Platform.isMacOS;
    final title = '${_l.label} ⇄ ${_r.label}';
    return AppBar(
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
      actions: [_queueButton(), const SizedBox(width: 4)],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(3),
        child: _queueProgressLine(),
      ),
    );
  }

  Widget _queueButton() {
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final n = _queue.activeCount;
        return IconButton(
          onPressed: _openQueue,
          tooltip: '传输队列',
          visualDensity: VisualDensity.compact,
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n'),
            backgroundColor: Et.accent,
            child: const Icon(Icons.swap_vert, size: 21),
          ),
        );
      },
    );
  }

  Widget _queueProgressLine() {
    return SizedBox(
      height: 3,
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
    );
  }

  Widget _body(bool compact) {
    return compact
        ? Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<int>(
                        segments: [
                          ButtonSegment(
                            value: 0,
                            icon: Icon(
                              _l.isLocal
                                  ? Icons.phone_android
                                  : Icons.dns_outlined,
                              size: 17,
                            ),
                            label: Text(_l.label),
                          ),
                          ButtonSegment(
                            value: 1,
                            icon: Icon(
                              _r.isLocal
                                  ? Icons.phone_android
                                  : Icons.dns_outlined,
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
                    if (widget.embedded) _queueButton(),
                  ],
                ),
              ),
              Expanded(
                child: _sideBody(_activeSide == 0 ? _l : _r, compact: true),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _dropPanel(_l, child: _sideBody(_l, compact: false)),
              ),
              VerticalDivider(width: 1, thickness: 1, color: Et.cardBorder),
              Expanded(
                child: _dropPanel(_r, child: _sideBody(_r, compact: false)),
              ),
            ],
          );
  }

  String _sideSubtitle(_Side s) => s.isLocal
      ? (s.lpath ?? '本机未选择目录')
      : '${s.spec.host!.username}@${s.spec.host!.hostname}:${s.rpath}';

  Widget _sideBody(_Side s, {required bool compact}) {
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
      final hint = s.localHint;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hint ?? '选择一个本机目录开始浏览',
              textAlign: TextAlign.center,
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
        _selectionBar(s, compact: compact),
        Expanded(
          child: s.isLocal
              ? _localList(s, compact: compact)
              : _remoteList(s, compact: compact),
        ),
      ],
    );
  }

  Widget _panelHeader(_Side s) {
    final picked = !s.isLocal || s.lpath != null;
    final crumbs = s.isLocal ? _localCrumbs(s) : _remoteCrumbs(s);
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
            child: crumbs.isEmpty
                ? Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'Menlo',
                      color: Et.textSecondary,
                    ),
                  )
                : _Crumbs(
                    crumbs: crumbs,
                    onJump: (i) {
                      final p = _crumbPath(s, crumbs, i);
                      if (s.isLocal) {
                        _jumpLocal(s, p);
                      } else {
                        _jumpRemote(s, p);
                      }
                    },
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

  Widget _remoteList(_Side s, {required bool compact}) {
    final entries = s.rentries;
    if (entries == null) return _note('读取目录中…', spinner: true);
    // 与本地列表同规则排序：目录在前，名称不区分大小写（评审 P2）
    final sorted = _sortedRemote(entries);
    final ordered = [for (final e in sorted) e.name];
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
      itemCount: sorted.length + (canUp ? 1 : 0),
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
        final canTransfer = _canTransfer(s);
        return _maybeDrag(
          enabled: !compact && canTransfer,
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
            selected: s.selection.contains(e.name),
            onSelect: () => _tapRow(s, e.name, ordered, touch: compact),
            onContextMenu: (pos) =>
                unawaited(_showRowMenu(s, _SelEntry.remote(e), pos)),
            // 手机没有右键：长按等价入口（桌面不用长按，避免鼠标长按误触）
            onLongPressMenu: compact
                ? (pos) => unawaited(_showRowMenu(s, _SelEntry.remote(e), pos))
                : null,
            actions: _rowActions(s, _SelEntry.remote(e)),
          ),
        );
      },
    );
  }

  Widget _localList(_Side s, {required bool compact}) {
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
    final canUpload = !_otherOf(s).isLocal && _otherOf(s).sessionId != null;
    final ordered = [for (final e in entries) e.name];
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
          enabled: !compact && !e.isDir && canUpload,
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
            selected: s.selection.contains(e.name),
            onSelect: () => _tapRow(s, e.name, ordered, touch: compact),
            onContextMenu: (pos) =>
                unawaited(_showRowMenu(s, _SelEntry.local(e), pos)),
            onLongPressMenu: compact
                ? (pos) => unawaited(_showRowMenu(s, _SelEntry.local(e), pos))
                : null,
            actions: _rowActions(s, _SelEntry.local(e)),
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

/// 拖放载荷：哪一侧的哪一行（锚点），附带锚点条目快照。
/// 落点只认 sideIndex；多选时由锚点是否在选区内解析出全部条目（见 _dragEntries），
/// 松手时才定稿；列表若在拖拽期间刷新，退回快照条目。
class _SftpDrag {
  const _SftpDrag({
    required this.sideIndex,
    required this.anchorName,
    this.remote,
    this.local,
  }) : assert(remote != null || local != null);

  final int sideIndex;
  final String anchorName;
  final sftp.SftpEntry? remote;
  final _LocalEntry? local;
}

/// 跟手的文件名芯片。左上角锚在指针上，再往右下偏一点，避免挡住落点。
/// 多选整拖时显示 "N 项"（数量 = 起拖那一刻的选区大小）。
class _DragChip extends StatelessWidget {
  const _DragChip({required this.name, required this.isDir, this.count = 1});

  final String name;
  final bool isDir;
  final int count;

  @override
  Widget build(BuildContext context) {
    final multi = count > 1;
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
                multi
                    ? Icons.copy_all_outlined
                    : (isDir
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined),
                size: 16,
                color: isDir || multi ? Et.tileGroup : Et.textSecondary,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  multi ? '$count 项' : name,
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

/// 行操作菜单项（⋮ 弹层与右键 showMenu 共用同一套渲染）。
List<PopupMenuEntry<int>> _menuItems(List<_RowAction> actions) => [
  for (var i = 0; i < actions.length; i++)
    PopupMenuItem(
      value: i,
      height: 40,
      child: Row(
        children: [
          Icon(
            actions[i].icon,
            size: 17,
            color: actions[i].destructive ? Et.danger : Et.textSecondary,
          ),
          const SizedBox(width: 8),
          // 主机标签可能很长（批量动作文案含对侧名称）：单项放不下就省略，
          // 否则 PopupMenu 宽度撑爆屏幕
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              actions[i].label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                color: actions[i].destructive ? Et.danger : Et.textPrimary,
              ),
            ),
          ),
        ],
      ),
    ),
];

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.isDir,
    required this.meta,
    required this.onOpen,
    required this.onSelect,
    this.selected = false,
    this.onContextMenu,
    this.onLongPressMenu,
    required this.actions,
  });

  final String name;
  final bool isDir;
  final String meta;
  final VoidCallback? onOpen;
  final VoidCallback onSelect;
  final bool selected;

  /// 右键菜单（桌面）：参数为指针全局坐标，菜单在该点弹出。
  final void Function(Offset globalPosition)? onContextMenu;

  /// 长按菜单（手机）：与右键同入口，参数为长按点全局坐标。
  final void Function(Offset globalPosition)? onLongPressMenu;

  final List<_RowAction> actions;

  @override
  Widget build(BuildContext context) {
    final row = ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: Et.accent.withValues(alpha: 0.16),
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
          fontWeight: isDir || selected ? FontWeight.w600 : FontWeight.w400,
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
        itemBuilder: (_) => _menuItems(actions),
      ),
      // 单击=选中（给视觉反馈与后续操作对象）；双击=打开/进入（Finder 习惯）
      onTap: onSelect,
    );
    if (onOpen == null && onContextMenu == null && onLongPressMenu == null) {
      return row;
    }
    return GestureDetector(
      onDoubleTap: onOpen,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!(d.globalPosition),
      onLongPressStart: onLongPressMenu == null
          ? null
          : (d) => onLongPressMenu!(d.globalPosition),
      child: row,
    );
  }
}

/// 路径面包屑：单击任一段跳转到该目录（本机侧钳制在授权根内）。
/// 段多时横向滚动，最后一段高亮表示当前位置。
class _Crumbs extends StatelessWidget {
  const _Crumbs({required this.crumbs, required this.onJump});

  final List<String> crumbs;
  final void Function(int index) onJump;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < crumbs.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Text(
                  '›',
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11.5,
                    color: Et.textSecondary,
                  ),
                ),
              ),
            InkWell(
              onTap: () => onJump(i),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                child: Text(
                  crumbs[i],
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11.5,
                    color: i == crumbs.length - 1
                        ? Et.textPrimary
                        : Et.textSecondary,
                    fontWeight: i == crumbs.length - 1
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
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
