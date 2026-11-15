// Hosts 页（Termius 式）：搜索 + Connect、工具栏、分组/主机卡片网格。
// 除 Hosts 外的导航项由壳层渲染为占位页（功能区随 M1/M2 落地）。

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';

import '../services/app_state.dart';
import 'add_host_dialog.dart';
import 'theme.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({super.key, required this.app, required this.onOpenTerminal});

  final AppState app;
  final void Function(HostView) onOpenTerminal;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  final _search = TextEditingController();
  String? _groupFilter; // null = 全部

  @override
  void initState() {
    super.initState();
    widget.app.refresh();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<HostView> get _matched {
    final q = _search.text.trim().toLowerCase();
    var list = widget.app.hosts;
    if (_groupFilter != null) {
      list = list.where((h) => h.groupId == _groupFilter).toList();
    }
    if (q.isNotEmpty) {
      list = list
          .where((h) =>
              h.label.toLowerCase().contains(q) ||
              h.hostname.toLowerCase().contains(q) ||
              h.username.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  void _connect(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机没有可用凭据（私钥仅会话内有效，请删除后重新添加）')),
      );
      return;
    }
    widget.onOpenTerminal(h);
  }

  Future<void> _addHost() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => AddHostDialog(app: widget.app),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('主机已保存并同步')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final g = widget.app.groups;
        final h = _matched;
        final exact = h.length == 1 ? h.first : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索行
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Et.cardBorder),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.search,
                              size: 18, color: Et.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              style: const TextStyle(
                                  fontSize: 13.5, color: Et.textPrimary),
                              decoration: const InputDecoration(
                                hintText: '查找主机或 user@hostname…',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: exact == null
                        ? null
                        : () => _connect(exact),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      disabledBackgroundColor: const Color(0xFFC9CBD3),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white60,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('Connect'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // 工具栏行
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _addHost,
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('新建主机'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_groupFilter != null)
                    InputChip(
                      label: Text(widget.app.groupName(_groupFilter) ?? '分组'),
                      onDeleted: () => setState(() => _groupFilter = null),
                      backgroundColor: Colors.white,
                    ),
                  const Spacer(),
                  _viewToggle(Icons.grid_view_rounded, true),
                  _viewToggle(Icons.style_outlined, false),
                  _viewToggle(Icons.keyboard_alt_outlined, false),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: widget.app.error != null
                    ? _CenterNote('同步失败: ${widget.app.error}')
                    : _grid(groups: g, hosts: h),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(HostView h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除主机',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Et.textPrimary)),
        content: Text('将从你的 vault 中删除「${h.label}」（${h.username}@${h.hostname}），'
            '关联的凭据一并下线。此操作会同步到所有设备。',
            style: const TextStyle(fontSize: 13.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD1242F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.app.deleteHost(h);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败: ${e.error}')));
    }
  }

  Widget _viewToggle(IconData icon, bool active) => IconButton(
        onPressed: () {},
        icon: Icon(icon,
            size: 19,
            color: active ? Et.textPrimary : const Color(0xFFB9BDC7)),
      );

  Widget _grid({required List<GroupView> groups, required List<HostView> hosts}) {
    if (widget.app.loading && hosts.isEmpty) {
      return const _CenterNote('同步中…');
    }
    if (hosts.isEmpty && groups.isEmpty) {
      return const _CenterNote('还没有主机，点「新建主机」添加');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_groupFilter == null && groups.isNotEmpty) ...[
            const _SectionTitle('分组'),
            _cardGrid(
              count: groups.length,
              build: (i) => _GroupCard(
                group: groups[i],
                onTap: () => setState(() => _groupFilter = groups[i].id),
              ),
            ),
          ],
          _SectionTitle(_groupFilter == null ? '主机' : '分组主机'),
          _cardGrid(
            count: hosts.length,
            build: (i) {
              final h = hosts[i];
              return _HostCard(
                host: h,
                groupName: widget.app.groupName(h.groupId),
                onTap: () => _connect(h),
                onDelete: () => _confirmDelete(h),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 响应式 N 列卡片网格（Termius 三列观感）。
  Widget _cardGrid({required int count, required Widget Function(int) build}) {
    return LayoutBuilder(builder: (context, box) {
      final cols = ((box.maxWidth ~/ 320) + 1).clamp(1, 4);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisExtent: 84,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: count,
        itemBuilder: (_, i) => build(i),
      );
    });
  }
}

class _CenterNote extends StatelessWidget {
  const _CenterNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: const TextStyle(color: Et.textSecondary)),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 0, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
      );
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.color, required this.icon});
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTap});
  final GroupView group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: onTap,
      child: Row(
        children: [
          const _IconTile(color: Et.tileGroup, icon: Icons.grid_view_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Text('${group.count} 台主机',
                    style: const TextStyle(
                        fontSize: 12.5, color: Et.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.groupName,
    required this.onTap,
    required this.onDelete,
  });
  final HostView host;
  final String? groupName;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = ['ssh', if (host.username.isNotEmpty) host.username,
      if (groupName != null) groupName].join(', ');
    return _Card(
      onTap: onTap,
      child: Row(
        children: [
          const _IconTile(color: Et.tileHost, icon: Icons.dns_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: Et.textSecondary)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz,
                size: 18, color: Et.textSecondary),
            tooltip: '操作',
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: const RelativeRect.fromLTRB(0, 0, 0, 0),
      items: const [
        PopupMenuItem(
            value: 'delete',
            height: 40,
            child: Text('删除主机',
                style: TextStyle(fontSize: 13.5, color: Color(0xFFD1242F)))),
      ],
    ).then((v) {
      if (v == 'delete') onDelete();
    });
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Et.cardRadius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(color: Et.cardBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: child,
        ),
      ),
    );
  }
}

// 占位导航页导出（shell 用）
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.title, required this.note});
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 6),
            Text(note,
                style: const TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}
