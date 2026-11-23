// SFTP 一级入口页（任务清单 #6）：选两台服务器（或一侧本机）后进入双侧传输页。
// 源/目标两个槽位，点选弹主机列表（含"本机"）；不允许两侧都为本机。

import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
import 'sftp_page.dart';
import 'theme.dart';

/// 弹层哨兵：区分"明确选择本机"与"取消关闭"（取消为 null 不落盘）。
class _LocalPick {
  const _LocalPick();
}

class SftpEntryPage extends StatefulWidget {
  const SftpEntryPage({super.key, required this.app});

  final AppState app;

  @override
  State<SftpEntryPage> createState() => _SftpEntryPageState();
}

class _SftpEntryPageState extends State<SftpEntryPage> {
  HostView? _left; // null = 本机
  HostView? _right; // null = 本机

  bool get _bothLocal => _left == null && _right == null;
  bool get _canStart => !_bothLocal;

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    final compact = MediaQuery.sizeOf(context).width < 720;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final hosts = widget.app.hosts;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 24,
            compact ? 8 : 18,
            compact ? 16 : 24,
            24,
          ),
          children: [
            if (!compact)
              Text(
                'SFTP',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Et.textPrimary,
                ),
              ),
            if (!compact) const SizedBox(height: 12),
            Text(
              '选择两侧的传输端点',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '两侧可为任意两台服务器，也可以一侧选本机。',
              style: TextStyle(fontSize: 13, color: Et.textSecondary),
            ),
            const SizedBox(height: 16),
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _slot(
                      context,
                      _left,
                      '源端',
                      Icons.upload_outlined,
                      () => _pick(0, hosts),
                    ),
                  ),
                  // 交换按钮（评审 P1：此前是死图标）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Center(
                      child: IconButton(
                        onPressed: (_left == null && _right == null)
                            ? null
                            : () => setState(() {
                                final t = _left;
                                _left = _right;
                                _right = t;
                              }),
                        tooltip: '交换源端与目标端',
                        icon: Icon(
                          Icons.swap_horiz,
                          size: 24,
                          color: Et.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _slot(
                      context,
                      _right,
                      '目标端',
                      Icons.download_outlined,
                      () => _pick(1, hosts),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 禁用给原因（评审 P1：此前「打开 SFTP」灰着无解释）
            if (!_canStart)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '两侧都是本机：至少一侧选择一台服务器才能开始传输',
                  style: TextStyle(fontSize: 12.5, color: Et.textSecondary),
                ),
              ),
            FilledButton.icon(
              onPressed: _canStart ? _start : null,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('打开 SFTP'),
              style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn,
                disabledBackgroundColor: Et.sidebarSelected,
                foregroundColor: Et.primaryBtnText,
                disabledForegroundColor: Et.textSecondary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                minimumSize: const Size(0, 46),
              ),
            ),
            const SizedBox(height: 24),
            _hintCard(),
          ],
        );
      },
    );
  }

  Widget _hintCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      border: Border.all(color: Et.cardBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '传输能力说明',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        _hintRow('文件', '远端 ↔ 本机 / 远端 ↔ 远端（经客户端分块中转）'),
        _hintRow('桌面拖放', '双栏按住文件拖到对侧面板，松手传到当前目录'),
        _hintRow('目录 → 本机', '自动打包压缩下载为 .tar.gz'),
        _hintRow('目录 → 远端', '递归复制（重试自动跳过已完成文件）'),
      ],
    ),
  );

  Widget _hintRow(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            k,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Et.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(fontSize: 12.5, color: Et.textSecondary),
          ),
        ),
      ],
    ),
  );

  Widget _slot(
    BuildContext context,
    HostView? host,
    String role,
    IconData icon,
    VoidCallback onPick,
  ) {
    final label = host?.label ?? '本机';
    final sub = host == null
        ? '本机工作区（自主选目录）'
        : '${host.username}@${host.hostname}';
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(Et.cardRadius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(color: Et.cardBorder),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: Et.accent),
                  const SizedBox(width: 6),
                  Text(
                    role,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Et.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    host == null ? Icons.phone_android : Icons.dns,
                    size: 22,
                    color: host == null ? Et.textSecondary : Et.tileHost,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Et.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Et.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(int slot, List<HostView> hosts) async {
    // ⚠️ 勿改回 showModalBottomSheet：模态底部弹层贴窗口底边且高度上限 9/16
    // （bottom_sheet.dart 的 _BottomSheetLayout，isScrollControlled=false 时），
    // 主机多时底部内容被切在屏幕外、桌面端无滚动条难以察觉，且与 app 内其他
    // 居中 AlertDialog 风格不一致。
    final result = await showDialog<Object?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
        title: Text(
          '选择${slot == 0 ? '源' : '目标'}端',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: ConstrainedBox(
          // 高度封顶 60% 屏高：主机再多也整体在屏内，超出部分列表内滚动
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              ListTile(
                leading: Icon(Icons.phone_android, color: Et.textSecondary),
                title: Text(
                  '本机',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '本机工作区目录',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary),
                ),
                onTap: () => Navigator.pop(ctx, const _LocalPick()),
              ),
              for (final h in hosts)
                ListTile(
                  leading: Icon(Icons.dns, color: Et.tileHost),
                  title: Text(
                    h.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Et.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '${h.username}@${h.hostname}',
                    style: TextStyle(fontSize: 12, color: Et.textSecondary),
                  ),
                  trailing: widget.app.credentialFor(h).available
                      ? null
                      : Text(
                          '无凭据',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: const Color(0xFFC77B27),
                          ),
                        ),
                  onTap: () => Navigator.pop(ctx, h),
                ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return; // 取消
    if (!mounted) return; // 弹层期间页面可能已销毁（IndexedStack 切页）
    setState(() {
      if (slot == 0) {
        _left = result is HostView ? result : null;
      } else {
        _right = result is HostView ? result : null;
      }
    });
  }

  void _start() {
    final leftSpec = _specFor(_left);
    final rightSpec = _specFor(_right);
    if (leftSpec == null || rightSpec == null) return; // 无凭据已被入口拦截
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpDualPage(left: leftSpec, right: rightSpec),
      ),
    );
  }

  SftpSideSpec? _specFor(HostView? h) {
    if (h == null) return const SftpSideSpec(); // 本机
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${h.label} 没有可用凭据，请先在编辑主机中补充')));
      return null;
    }
    return SftpSideSpec(host: h, authKind: cred.authKind, secret: cred.secret);
  }
}
