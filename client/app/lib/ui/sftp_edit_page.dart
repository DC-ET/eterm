// 远端文本编辑页（跨平台）：下载到应用临时目录 → 应用内编辑 → 保存前 mtime 校验 → 覆盖回传。
// >2MB 或二进制（首 8KB 含 NUL）或非 UTF-8 文本拒绝编辑。
// 不走外部编辑器/watcher（Android 无跨应用文件编辑回传的可靠通路），两端同一套交互。

import 'dart:convert';
import 'dart:io';

import 'package:eterm/services/sftp_transfer_queue.dart';
import 'package:eterm/src/rust/api/sftp.dart' as sftp;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'terminal_gestures.dart'; // TerminalPrefs（编辑器字号跟随终端偏好）
import 'theme.dart';
import 'ui_utils.dart';

/// 文本编辑大小上限（字节）：TextField 内存态全量编辑的现实边界。
const _kMaxEditBytes = 2 * 1024 * 1024;

enum _EditPhase { loading, editing, saving, failed }

class SftpEditPage extends StatefulWidget {
  const SftpEditPage({
    super.key,
    required this.hostLabel,
    required this.sessionId,
    required this.remotePath,
  });

  final String hostLabel;
  final BigInt sessionId;
  final String remotePath;

  @override
  State<SftpEditPage> createState() => _SftpEditPageState();
}

class _SftpEditPageState extends State<SftpEditPage> {
  _EditPhase _phase = _EditPhase.loading;
  String? _reason;
  final TextEditingController _ctrl = TextEditingController();
  bool _dirty = false;
  int? _baseMtime; // 下载时的远端 mtime（保存前比对）
  (int, int)? _prog; // 下载/回传进度（transferred, total）

  String get _name => widget.remotePath.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<String> _tempPath() async {
    final tmp = await getTemporaryDirectory();
    // 主机名只留安全字符，附 sessionId 防不同主机同名路径互踩
    final safe =
        widget.hostLabel.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dir = Directory(
        '${tmp.path}/eterm-sftp-edit/$safe-${widget.sessionId}');
    await dir.create(recursive: true);
    return '${dir.path}/$_name';
  }

  Future<void> _load() async {
    if (_phase == _EditPhase.loading || _phase == _EditPhase.saving) {
      return; // 防重入（双击重试会并发两个下载写同一暂存）
    }
    setState(() {
      _phase = _EditPhase.loading;
      _reason = null;
      _prog = null;
    });
    try {
      final id = widget.sessionId;
      final st = await sftp.sftpStat(id: id, path: widget.remotePath);
      if (st == null) throw ('远端文件不存在');
      if (st.size.toInt() > _kMaxEditBytes) throw ('文件超过 2MB，暂不支持编辑');
      _baseMtime = st.mtime;

      final path = await _tempPath();
      var last = 0;
      await for (final p in sftp.sftpDownload(
        id: id,
        jobId: freshSftpJobId(),
        remotePath: widget.remotePath,
        localPath: path,
        resume: false,
      )) {
        last = p.transferred.toInt();
        if (mounted) setState(() => _prog = (last, p.total.toInt()));
      }
      final bytes = await File(path).readAsBytes();
      await File(path).delete();
      // 二进制启发式：首 8KB 出现 NUL 视为二进制
      final head = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
      if (head.contains(0)) throw ('二进制文件不支持文本编辑');
      final text = utf8.decode(bytes, allowMalformed: false);
      if (!mounted) return;
      setState(() {
        _ctrl.text = text;
        _dirty = false;
        _phase = _EditPhase.editing;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _EditPhase.failed;
        _reason = '$e';
      });
    }
  }

  Future<void> _save() async {
    if (!_dirty || _phase != _EditPhase.editing) return;
    // 先同步置 saving 再 await：双击保存不会并发跑两个 _save（各自 pop 会连退两层）
    setState(() {
      _phase = _EditPhase.saving;
      _prog = null;
    });
    try {
      // 保存前校验远端是否被别人改过
      final st =
          await sftp.sftpStat(id: widget.sessionId, path: widget.remotePath);
      if (st != null && _baseMtime != null && st.mtime != _baseMtime) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Et.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('远端文件已变化',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Et.textPrimary)),
            content: Text('远端文件在本次编辑期间被修改过（可能为其他会话或用户）。覆盖保存将丢失那部分改动。',
                style: TextStyle(
                    fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('取消',
                      style: TextStyle(color: Et.textSecondary))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9))),
                  child: const Text('仍要覆盖')),
            ],
          ),
        );
        if (ok != true || !mounted) {
          if (mounted) {
            setState(() => _phase = _EditPhase.editing);
          }
          return;
        }
      }
      final tmpPath = await _writeTemp();
      await for (final p in sftp.sftpUpload(
        id: widget.sessionId,
        jobId: freshSftpJobId(),
        localPath: tmpPath,
        remotePath: widget.remotePath,
        resume: false,
      )) {
        if (mounted) setState(() => _prog = (p.transferred.toInt(), p.total.toInt()));
      }
      // 清掉本次保存的临时文件（cache 目录，失败忽略）
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      // 刷新 mtime 基线：否则下次保存必然误报"远端文件已变化"（自己刚改过）
      try {
        final st2 =
            await sftp.sftpStat(id: widget.sessionId, path: widget.remotePath);
        _baseMtime = st2?.mtime;
      } catch (_) {
        _baseMtime = null; // stat 失败则跳过下次校验（宁可不弹不误弹）
      }
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _phase = _EditPhase.editing;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存并回传远端')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _EditPhase.editing);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  /// 把编辑内容写入临时文件供上传（上传接口走文件路径）。
  Future<String> _writeTemp() async {
    final path = await _tempPath();
    await File(path).writeAsString(_ctrl.text);
    return path;
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    final compact = MediaQuery.sizeOf(context).width < 720;
    final macGap = !compact && Platform.isMacOS;
    return PopScope(
      canPop: !_dirty || _phase != _EditPhase.editing,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _phase != _EditPhase.editing || !_dirty) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Et.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('放弃修改？',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Et.textPrimary)),
            content: Text('有未保存的修改，返回将丢失。',
                style: TextStyle(
                    fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('继续编辑',
                      style: TextStyle(color: Et.textSecondary))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                      backgroundColor: Et.danger,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9))),
                  child: const Text('放弃修改')),
            ],
          ),
        );
        if (discard == true && context.mounted) {
          // 放弃拦截后真正退出
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Et.contentBg,
        appBar: AppBar(
          // macOS 隐藏标题栏窗口：leading 让位交通灯（+48 保证 BackButton
          // 完整命中区，与 SFTP 双栏页同源）
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
              Text(_name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16.5, fontWeight: FontWeight.w600)),
              Text(widget.remotePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Menlo',
                      color: Et.textSecondary)),
            ],
          ),
          actions: [
            if (_phase == _EditPhase.editing || _phase == _EditPhase.saving)
              _dirty
                  ? IconButton(
                      onPressed: _phase == _EditPhase.editing ? _save : null,
                      tooltip: '保存并回传',
                      icon: _phase == _EditPhase.saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_outlined, size: 21),
                    )
                  : Padding(
                      padding: EdgeInsets.only(right: 14),
                      child: Center(
                          child: Text('已保存',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Et.textSecondary))),
                    ),
            const SizedBox(width: 4),
          ],
        ),
        body: switch (_phase) {
          _EditPhase.loading || _EditPhase.saving => _progressView(),
          _EditPhase.failed => _failedView(),
          _EditPhase.editing => Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Container(
                decoration: BoxDecoration(
                  color: Et.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Et.cardBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // 桌面快捷键：Cmd/Ctrl+S 保存（评审 P1）
                child: CallbackShortcuts(
                  bindings: {
                    SingleActivator(LogicalKeyboardKey.keyS,
                            meta: Platform.isMacOS,
                            control: !Platform.isMacOS):
                        _save,
                  },
                  child: ValueListenableBuilder<double>(
                    valueListenable: TerminalPrefs.fontSize,
                    builder: (context, fontSize, _) => TextField(
                      controller: _ctrl,
                      onChanged: (_) {
                        if (!_dirty) setState(() => _dirty = true);
                      },
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      // 字号跟随终端偏好（评审 P2：此前硬编码 13 不随设置；
                      // TerminalPrefs 已由设置页滑杆约束范围）
                      style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: fontSize,
                          height: 1.5),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: '文件内容为空',
                      ),
                    ),
                  ),
                ),
              ),
            ),
        },
      ),
    );
  }

  Widget _progressView() {
    final p = _prog;
    final total = p?.$2 ?? 0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 12),
          Text(
            p == null
                ? (_phase == _EditPhase.saving ? '回传中…' : '读取中…')
                : total > 0
                    ? '${_phase == _EditPhase.saving ? "回传中" : "读取中"} '
                        '${_fmtSize(p.$1)}/${_fmtSize(total)}'
                    : (_phase == _EditPhase.saving ? '回传中…' : '读取中…'),
            style: TextStyle(fontSize: 12.5, color: Et.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _failedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_reason ?? '加载失败',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 13, color: Et.textSecondary)),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn, foregroundColor: Et.primaryBtnText),
          ),
        ],
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }
}
