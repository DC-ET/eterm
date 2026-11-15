// SFTP 文件浏览/传输页（M2）：独立 SSH 连接（数据面直连目标主机，不经中枢）。
// 浏览为请求-响应（sftp_list），传输为进度流（sftp_download/upload 的 Stream）。
// 文件选择走 file_selector（Android SAF / macOS NSSavePanel）。

import 'dart:async';

import 'package:eterm/src/rust/api/sftp.dart' as sftp;
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
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

class _SftpPageState extends State<SftpPage> {
  BigInt? _id;
  _Phase _phase = _Phase.connecting;
  String? _reason;
  String _path = '/';
  List<sftp.SftpEntry>? _entries; // null = 列表加载中
  bool _busy = false; // 任一传输/写操作进行中（防并发操作同一会话）
  StreamSubscription<sftp.SftpProgress>? _transferSub;
  // 传输进度：label + 0..1（null = 未知大小，不定值条）
  (String, double?)? _prog;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _transferSub?.cancel();
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
    try {
      final id = await sftp.sftpConnect(
        host: widget.host.hostname,
        port: widget.host.port,
        user: widget.host.username,
        authKind: widget.authKind,
        secret: widget.secret,
      );
      final real = await sftp.sftpRealpath(id: id, path: '.');
      if (!mounted) return;
      setState(() {
        _id = id;
        _phase = _Phase.live;
        _path = real.isEmpty ? '/' : real;
      });
      await _list();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _reason = '$e';
      });
    }
  }

  Future<void> _list() async {
    final id = _id;
    if (id == null) return;
    setState(() => _entries = null);
    try {
      final items = await sftp.sftpList(id: id, path: _path);
      if (!mounted) return;
      setState(() => _entries = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _entries = []);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取目录失败: $e')));
    }
  }

  String _join(String name) =>
      _path.endsWith('/') ? '$_path$name' : '$_path/$name';

  void _enter(sftp.SftpEntry e) {
    setState(() => _path = _join(e.name));
    _list();
  }

  void _up() {
    if (_path == '/' || _path.isEmpty) return;
    final idx = _path.lastIndexOf('/');
    setState(() => _path = idx <= 0 ? '/' : _path.substring(0, idx));
    _list();
  }

  // ---------- 写操作 ----------

  Future<void> _mkdir() async {
    final name = await _promptText('新建文件夹', '文件夹名称');
    if (name == null || name.isEmpty) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await sftp.sftpMkdir(id: id, path: _join(name));
      await _list();
    } catch (e) {
      _err('创建失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(sftp.SftpEntry e) async {
    final name = await _promptText('重命名', '新名称', initial: e.name);
    if (name == null || name.isEmpty || name == e.name) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await sftp.sftpRename(id: id, from: _join(e.name), to: _join(name));
      await _list();
    } catch (e2) {
      _err('重命名失败: $e2');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(sftp.SftpEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            e.isDir ? '删除空目录「${e.name}」？（目录须为空）' : '删除文件「${e.name}」？不可恢复。',
            style: const TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD1242F),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (e.isDir) {
        await sftp.sftpRmdir(id: id, path: _join(e.name));
      } else {
        await sftp.sftpRemove(id: id, path: _join(e.name));
      }
      await _list();
    } catch (e2) {
      _err('删除失败: $e2');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 传输 ----------

  Future<void> _upload() async {
    final id = _id;
    if (id == null || _busy) return;
    final XFile? file = await openFile();
    if (file == null || !mounted) return;
    final name = file.name;
    setState(() {
      _busy = true;
      _prog = ('上传 $name', null);
    });
    var failed = false;
    _transferSub = sftp
        .sftpUpload(id: id, localPath: file.path, remotePath: _join(name))
        .listen((p) {
      if (!mounted) return;
      final total = p.total.toInt();
      setState(() {
        _prog = (
          '上传 $name ${_fmtSize(p.transferred)}/${_fmtSize(p.total)}',
          total > 0 ? p.transferred.toInt() / total : null
        );
      });
    }, onError: (Object e) {
      failed = true;
      _err('上传失败: $e');
    }, onDone: () {
      if (mounted) {
        setState(() {
          _busy = false;
          _prog = null;
        });
        if (!failed) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已上传 $name')));
        }
      }
      _list();
    });
  }

  Future<void> _download(sftp.SftpEntry e) async {
    final id = _id;
    if (id == null || _busy) return;
    final location = await getSaveLocation(suggestedName: e.name);
    if (location == null || !mounted) return;
    setState(() {
      _busy = true;
      _prog = ('下载 ${e.name}', null);
    });
    var failed = false;
    _transferSub = sftp
        .sftpDownload(
            id: id, remotePath: _join(e.name), localPath: location.path)
        .listen((p) {
      if (!mounted) return;
      final total = p.total.toInt();
      setState(() {
        _prog = (
          '下载 ${e.name} ${_fmtSize(p.transferred)}/${_fmtSize(p.total)}',
          total > 0 ? p.transferred.toInt() / total : null
        );
      });
    }, onError: (Object e2) {
      failed = true;
      _err('下载失败: $e2');
    }, onDone: () {
      if (mounted) {
        setState(() {
          _busy = false;
          _prog = null;
        });
        if (!failed) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已下载 ${e.name}')));
        }
      }
    });
  }

  // ---------- 辅助 ----------

  void _err(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _prog = null;
    });
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

  static String _fmtSize(BigInt bytes) {
    final b = bytes.toInt();
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)}M';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}G';
  }

  static String _fmtTime(int unixSecs) {
    final t = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm';
  }

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
            Text(_path,
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
            onPressed: (_phase == _Phase.live && !_busy) ? _upload : null,
            tooltip: '上传文件',
            icon: const Icon(Icons.upload_file_outlined, size: 21),
          ),
          IconButton(
            onPressed: (_phase == _Phase.live && !_busy) ? _mkdir : null,
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined, size: 21),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_prog != null) ...[
            LinearProgressIndicator(
              value: _prog!.$2,
              minHeight: 3,
              color: Et.accent,
              backgroundColor: Et.cardBorder,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_prog!.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Et.textSecondary)),
                ),
              ]),
            ),
          ],
          Expanded(
            child: switch (_phase) {
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
              _Phase.live => _browser(compact),
            },
          ),
        ],
      ),
    );
  }

  Widget _browser(bool compact) {
    final entries = _entries;
    if (entries == null) {
      return _note('读取目录中…', spinner: true);
    }
    final canUp = _path != '/' && _path.isNotEmpty;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(compact ? 6 : 12, 4, compact ? 6 : 12, 20),
      itemCount: entries.length + (canUp ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && canUp) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward,
                size: 20, color: Et.textSecondary),
            title: const Text('..',
                style: TextStyle(fontFamily: 'Menlo', fontSize: 13.5)),
            onTap: _up,
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
          onOpen: e.isDir ? () => _enter(e) : null,
          onDownload: e.isDir ? null : () => _download(e),
          onRename: () => _rename(e),
          onDelete: () => _delete(e),
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

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.isDir,
    required this.meta,
    required this.onOpen,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final bool isDir;
  final String meta;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;

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
      trailing: PopupMenuButton<String>(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        icon: const Icon(Icons.more_vert, size: 19, color: Et.textSecondary),
        onSelected: (v) {
          switch (v) {
            case 'download':
              onDownload?.call();
            case 'rename':
              onRename();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (_) => [
          if (onDownload != null)
            const PopupMenuItem(
                value: 'download',
                height: 40,
                child: Text('下载…',
                    style:
                        TextStyle(fontSize: 13.5, color: Et.textPrimary))),
          const PopupMenuItem(
              value: 'rename',
              height: 40,
              child: Text('重命名',
                  style: TextStyle(fontSize: 13.5, color: Et.textPrimary))),
          const PopupMenuItem(
              value: 'delete',
              height: 40,
              child: Text('删除',
                  style:
                      TextStyle(fontSize: 13.5, color: Color(0xFFD1242F)))),
        ],
      ),
      onTap: onOpen,
    );
  }
}
