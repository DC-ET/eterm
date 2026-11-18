// Hosts 页（Termius 式）：搜索 + Connect、工具栏、分组/主机卡片网格。
// 卡片：点击连接、右键/长按快捷菜单（连接/编辑/删除）；有打开终端的主机显示状态点。

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'add_host_dialog.dart';
import 'sftp_page.dart';
import 'theme.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    super.key,
    required this.app,
    required this.onOpenTerminal,
    required this.openHostIds,
    this.onLogout,
    this.mobileUsername = '',
  });

  final AppState app;
  final void Function(HostView) onOpenTerminal;
  final Set<String> openHostIds; // 已开终端标签的主机 id
  final VoidCallback? onLogout; // 手机 app bar 账号菜单用（桌面走侧栏/标题栏）
  final String mobileUsername; // 手机 app bar 账号菜单展示

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  final _search = TextEditingController();
  String? _groupFilter; // null = 全部
  bool _showSearch = false; // 手机 app bar 搜索展开

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
    if (!widget.app.credentialFor(h).available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机还没有凭据，请通过卡片菜单「编辑主机」补充')),
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

  Future<void> _editHost(HostView h) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AddHostDialog.edit(app: widget.app, editHost: h),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('主机已更新并同步')));
    }
  }

  Future<void> _confirmDelete(HostView h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除主机',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将从你的 vault 中删除「${h.label}」（${h.username}@${h.hostname}），'
            '关联的凭据一并下线。此操作会同步到所有设备。',
            style: TextStyle(fontSize: 13.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.danger,
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
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

  void _cardMenu(HostView h, Offset anchorTopLeft, Size anchorSize) {
    showMenu<String>(
      context: context,
      color: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromLTRB(
        anchorTopLeft.dx,
        anchorTopLeft.dy + anchorSize.height,
        anchorTopLeft.dx + anchorSize.width,
        0,
      ),
      items: [
        PopupMenuItem(
            value: 'connect',
            height: 40,
            child: _MenuItemText('连接终端', Et.textPrimary)),
        PopupMenuItem(
            value: 'sftp',
            height: 40,
            child: _MenuItemText('SFTP 文件', Et.textPrimary)),
        PopupMenuItem(
            value: 'edit',
            height: 40,
            child: _MenuItemText('编辑主机', Et.textPrimary)),
        PopupMenuItem(
            value: 'delete',
            height: 40,
            child: _MenuItemText('删除主机', Et.danger)),
      ],
    ).then((v) {
      if (!mounted || v == null) return;
      switch (v) {
        case 'connect':
          _connect(h);
        case 'sftp':
          _openSftp(h);
        case 'edit':
          _editHost(h);
        case 'delete':
          _confirmDelete(h);
      }
    });
  }

  /// 打开 SFTP 浏览页（凭据与终端同一解析链：identity → password/ssh_key）。
  void _openSftp(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机还没有凭据，请通过卡片菜单「编辑主机」补充')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          SftpPage(host: h, authKind: cred.authKind, secret: cred.secret),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final g = widget.app.groups;
        final h = _matched;
        final exact = h.length == 1 ? h.first : null;
        final compact = MediaQuery.sizeOf(context).width < 720; // 手机竖屏
        if (compact) return _mobileHosts(context, groups: g, hosts: h);
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
                        color: Et.card,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Et.cardBorder),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Icon(Icons.search,
                              size: 18, color: Et.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              style: TextStyle(
                                  fontSize: 13.5, color: Et.textPrimary),
                              // 回车：唯一匹配直接连接
                              onSubmitted: (_) =>
                                  exact == null ? null : _connect(exact),
                              decoration: const InputDecoration(
                                hintText: '查找主机或 user@hostname…（回车连接唯一匹配）',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          if (_search.text.isNotEmpty)
                            InkWell(
                              onTap: () {
                                _search.clear();
                                setState(() => _groupFilter = null);
                              },
                              child: Icon(Icons.close,
                                  size: 16, color: Et.textSecondary),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: exact == null ? null : () => _connect(exact),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      disabledBackgroundColor: const Color(0xFFC9CBD3),
                      foregroundColor: Et.primaryBtnText,
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
                      foregroundColor: Et.primaryBtnText,
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
                      backgroundColor: Et.card,
                    ),
                  const Spacer(),
                  _viewToggle(Icons.grid_view_rounded, true),
                  _viewToggle(Icons.style_outlined, false),
                  _viewToggle(Icons.keyboard_alt_outlined, false),
                ],
              ),
              const SizedBox(height: 8),
              // 同步进度细条
              if (widget.app.loading)
                LinearProgressIndicator(
                    minHeight: 2, color: Et.accent, backgroundColor: Et.card),
              Expanded(
                child: widget.app.error == 'unauthorized'
                    ? const SizedBox.shrink() // 壳层正在跳转登录页
                    : Column(
                        children: [
                          // 同步失败不打断本地快照展示（离线可见）
                          if (widget.app.error != null)
                            _errorBanner(widget.app.error!),
                          Expanded(child: _grid(groups: g, hosts: h)),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 手机布局（Termius 式：浅色 app bar + 单列列表卡 + FAB） ----------

  Widget _mobileHosts(BuildContext context,
      {required List<GroupView> groups, required List<HostView> hosts}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_groupFilter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: InputChip(
              label: Text('分组：${widget.app.groupName(_groupFilter) ?? ''}'),
              onDeleted: () => setState(() => _groupFilter = null),
              backgroundColor: Et.card,
            ),
          ),
        Expanded(
          child: widget.app.error == 'unauthorized'
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    if (widget.app.error != null)
                      _errorBanner(widget.app.error!),
                    Expanded(
                        child: _mobileList(groups: groups, hosts: hosts)),
                  ],
                ),
        ),
      ],
    );
    return Container(
      color: Et.mBg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _mobileAppBar(context),
              if (_showSearch) _mobileSearch(),
              if (widget.app.loading)
                LinearProgressIndicator(
                    minHeight: 2, color: Et.accent),
              Expanded(child: content),
            ],
          ),
          // FAB：新建主机
          Positioned(
            right: 18,
            bottom: 84,
            child: Material(
              color: Et.mFab,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                onTap: _addHost,
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: Icon(Icons.add, size: 30, color: Et.mFabIcon),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
      child: Row(
        children: [
          // 账号胶囊：点击弹菜单（登出）
          InkWell(
            onTap: () => _accountMenu(context),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: Et.card.withAlpha(150),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.dns, size: 17, color: Et.textPrimary),
                  SizedBox(width: 6),
                  Text('Vaults',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Et.textPrimary)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text('Hosts',
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Et.textPrimary)),
          const Spacer(),
          IconButton(
            onPressed: () => setState(() => _showSearch = !_showSearch),
            icon: Icon(Icons.search, size: 23, color: Et.textPrimary),
            tooltip: '搜索',
          ),
        ],
      ),
    );
  }

  Widget _mobileSearch() {
    final h = _matched;
    final exact = h.length == 1 ? h.first : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: Et.card,
          borderRadius: BorderRadius.circular(21),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.search, size: 19, color: Et.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                style: TextStyle(fontSize: 14, color: Et.textPrimary),
                onSubmitted: (_) => exact == null ? null : _connect(exact),
                decoration: const InputDecoration(
                  hintText: '查找主机…',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            InkWell(
              onTap: () {
                _search.clear();
                setState(() => _showSearch = false);
              },
              child: Icon(Icons.close, size: 18, color: Et.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileList(
      {required List<GroupView> groups, required List<HostView> hosts}) {
    if (widget.app.loading && hosts.isEmpty && groups.isEmpty) {
      return const _CenterNote('同步中…');
    }
    if (hosts.isEmpty && groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.dns_outlined,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有主机',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('添加你的第一台服务器开始使用',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (_groupFilter == null && groups.isNotEmpty) ...[
          const _SectionTitle('分组'),
          for (final grp in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _MobileTile(
                iconColor: Et.tileGroup,
                icon: Icons.grid_view_rounded,
                title: grp.label,
                subtitle: grp.count == 0 ? '无主机' : '${grp.count} 台主机',
                onTap: () => setState(() => _groupFilter = grp.id),
              ),
            ),
        ],
        _SectionTitle(_groupFilter == null ? '主机' : '分组主机'),
        for (final host in hosts)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MobileTile(
              iconColor: Et.tileHost,
              icon: Icons.dns_rounded,
              title: host.label,
              subtitle: [
                'ssh',
                if (host.username.isNotEmpty) host.username,
                if (widget.app.groupName(host.groupId) != null)
                  widget.app.groupName(host.groupId)!,
                if (!widget.app.credentialFor(host).available) '无凭据',
              ].join(', '),
              danger: !widget.app.credentialFor(host).available,
              open: widget.openHostIds.contains(host.id),
              onTap: () => _connect(host),
              onMenu: (tl, size) => _cardMenu(host, tl, size),
            ),
          ),
      ],
    );
  }

  /// 同步失败横幅：保留本地快照渲染，仅提示 + 重试
  Widget _errorBanner(String message) {
    final danger = Et.danger;
    final bannerBg = Et.brightness == Brightness.dark
        ? Et.danger.withAlpha(26)
        : const Color(0xFFFCEDED);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bannerBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text('同步失败，正在显示本地缓存 · $message',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: danger)),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => widget.app.refresh(),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('重试',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: danger)),
            ),
          ),
        ],
      ),
    );
  }

  void _accountMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      color: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: const RelativeRect.fromLTRB(12, 52, 240, 0),
      items: [
        PopupMenuItem(
            enabled: false,
            child: Text('已登录：${widget.mobileUsername}',
                style: const TextStyle(fontSize: 13.5))),
        PopupMenuItem(
            value: 'logout',
            height: 40,
            child: Text('退出登录',
                style: TextStyle(fontSize: 13.5, color: Et.textPrimary))),
      ],
    ).then((v) {
      if (v == 'logout') widget.onLogout?.call();
    });
  }

  Widget _viewToggle(IconData icon, bool active) => IconButton(
        onPressed: () {},
        icon: Icon(icon,
            size: 19,
            color: active ? Et.textPrimary : const Color(0xFFB9BDC7)),
      );

  Widget _grid(
      {required List<GroupView> groups, required List<HostView> hosts}) {
    if (widget.app.loading && hosts.isEmpty) {
      return const _CenterNote('同步中…');
    }
    if (hosts.isEmpty && groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('还没有主机',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _addHost,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('新建主机'),
              style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                minimumSize: const Size(0, 38),
              ),
            ),
          ],
        ),
      );
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
                open: widget.openHostIds.contains(h.id),
                hasCredential: widget.app.credentialFor(h).available,
                onTap: () => _connect(h),
                onMenu: (anchorTopLeft, anchorSize) =>
                    _cardMenu(h, anchorTopLeft, anchorSize),
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

class _MenuItemText extends StatelessWidget {
  const _MenuItemText(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 13.5, color: color));
}

class _CenterNote extends StatelessWidget {
  const _CenterNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: TextStyle(color: Et.textSecondary)),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 0, 4),
        child: Text(text,
            style: TextStyle(
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
          _IconTile(color: Et.tileGroup, icon: Icons.grid_view_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Text('${group.count} 台主机',
                    style: TextStyle(
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
    required this.open,
    required this.hasCredential,
    required this.onTap,
    required this.onMenu,
  });

  final HostView host;
  final String? groupName;
  final bool open; // 已有打开的终端标签
  final bool hasCredential;
  final VoidCallback onTap;
  final void Function(Offset anchorTopLeft, Size anchorSize) onMenu;

  void _menuAt(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    onMenu(box.localToGlobal(Offset.zero), box.size);
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      'ssh',
      if (host.username.isNotEmpty) host.username,
      if (groupName != null) groupName,
    ].join(', ');
    return _Card(
      onTap: onTap,
      onSecondaryTapUp: (d) => _menuAt(context),
      onLongPress: () => _menuAt(context),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              _IconTile(color: Et.tileHost, icon: Icons.dns_rounded),
              if (open)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2DA44E),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Text(hasCredential ? subtitle : '$subtitle · 无凭据',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: hasCredential
                            ? Et.textSecondary
                            : const Color(0xFFC77B27))),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.more_horiz,
                size: 18, color: Et.textSecondary),
            tooltip: '操作',
            onPressed: () => _menuAt(context),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    required this.onTap,
    this.onSecondaryTapUp,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback onTap;
  final void Function(TapUpDetails)? onSecondaryTapUp;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: onSecondaryTapUp,
        onLongPress: onLongPress,
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

/// 手机列表卡（Termius 式）：大圆角白卡 + 48px 图标瓦片 + 名称/副标题。
/// 点击主操作（连接/进入分组），长按/⋯ 弹菜单。
class _MobileTile extends StatelessWidget {
  const _MobileTile({
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onMenu,
    this.danger = false,
    this.open = false,
  });

  final Color iconColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final void Function(Offset anchorTopLeft, Size anchorSize)? onMenu;
  final bool danger; // 无凭据橙色副标题
  final bool open; // 已开终端绿点

  void _menuAt(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    onMenu?.call(box.localToGlobal(Offset.zero), box.size);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu == null ? null : () => _menuAt(context),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: iconColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: Colors.white, size: 25),
                  ),
                  if (open)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2DA44E),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            color: danger
                                ? const Color(0xFFC77B27)
                                : Et.textSecondary)),
                  ],
                ),
              ),
              if (onMenu != null)
                IconButton(
                  icon: Icon(Icons.more_horiz,
                      size: 19, color: Et.textSecondary),
                  tooltip: '操作',
                  onPressed: () => _menuAt(context),
                ),
            ],
          ),
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
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Icon(Icons.construction,
                  size: 30, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: Et.textPrimary)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(note,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, height: 1.5, color: Et.textSecondary)),
            ),
          ],
        ),
      );
}
