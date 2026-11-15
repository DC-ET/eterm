// 应用壳（Termius 式）：深色自绘标题栏（Vaults 胶囊 + 终端标签 + 关闭），
// vault 视图 = 左侧导航 + 内容区；终端标签激活时满幅接管内容区（侧栏隐藏）。
// 窄屏（手机竖屏，<720）响应式：侧边导航换成底部导航栏，内容区满幅。
// IndexedStack 保持后台终端标签的会话存活。

import 'package:flutter/services.dart';

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/legacy.dart'; // 标题栏 DragToMoveArea
import 'package:xterm/xterm.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'hosts_page.dart';
import 'keychain_page.dart';
import 'logs_page.dart';
import 'known_hosts_page.dart';
import 'terminal_tab.dart';
import 'login_page.dart';
import 'theme.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    required this.api,
    required this.app,
    required this.username,
  });

  final ApiClient api;
  final AppState app;
  final String username;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _TerminalTab {
  _TerminalTab(this.host, this.authKind, this.secret) : key = UniqueKey();
  final UniqueKey key;
  final HostView host;
  final String authKind; // password | key
  final String secret;
  final Terminal terminal = Terminal(maxLines: 20000);
}

class _ShellPageState extends State<ShellPage> {
  final tabs = <_TerminalTab>[];
  int activeTab = -1; // -1 = vault 视图；否则 tabs 下标
  int navIndex = 0; // 侧边导航（0=Hosts）

  void openTerminal(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机没有可用凭据（私钥仅会话内有效，请删除后重新添加）')),
      );
      return;
    }
    final existing = tabs.indexWhere((t) => t.host.id == h.id);
    setState(() {
      if (existing >= 0) {
        activeTab = existing; // 复用已开终端
      } else {
        tabs.add(_TerminalTab(h, cred.authKind, cred.secret));
        activeTab = tabs.length - 1;
      }
    });
  }

  void closeTab(int i) {
    setState(() {
      tabs.removeAt(i);
      if (tabs.isEmpty) {
        activeTab = -1;
      } else if (activeTab >= tabs.length) {
        activeTab = tabs.length - 1;
      }
    });
  }

  Future<void> _logout() async {
    try {
      await widget.api.logout();
    } catch (_) {}
    local.clearLocal(); // 会话 + 本地缓存一并清理
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  /// token 失效（401）：静默回登录页。
  void _onAuthLost() {
    local.clearLocal();
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_appChanged);
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    super.dispose();
  }

  void _appChanged() {
    if (widget.app.error == 'unauthorized') {
      _onAuthLost();
      return;
    }
    if (mounted) setState(() {}); // 同步 loading 状态驱动进度条
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720; // 手机竖屏
    final content = switch (navIndex) {
      0 => HostsPage(
          app: widget.app,
          onOpenTerminal: openTerminal,
          openHostIds: {for (final t in tabs) t.host.id},
          onLogout: _logout,
          mobileUsername: widget.username,
        ),
      1 => KeychainPage(app: widget.app),
      2 => const PlaceholderPage(title: 'Port Forwarding', note: '端口转发管理随 M2 落地'),
      3 => const PlaceholderPage(title: 'Snippets', note: '代码片段随 M3 落地'),
      4 => const KnownHostsPage(),
      _ => const LogsPage(),
    };
    // 手机：内容满幅 + 底部导航（仅收纳有实质功能的页；占位页留在桌面侧栏）
    final vaultView = compact
        ? Column(
            children: [
              Expanded(
                child: SafeArea(bottom: false, child: content), // 状态栏统一避让
              ),
              SafeArea(
                top: false, // 手势条避让
                child: NavigationBar(
                  selectedIndex: _compactNavIndex(navIndex),
                  onDestinationSelected: (i) =>
                      setState(() => navIndex = _compactNavTarget[i]),
                  height: 62,
                  backgroundColor: Et.mBg,
                  indicatorColor: Et.mSelected,
                  destinations: [
                    for (final (icon, label) in _compactNav)
                      NavigationDestination(
                          icon: Icon(icon, size: 21), label: label),
                  ],
                ),
              ),
            ],
          )
        : Row(
            children: [
              _Sidebar(
                navIndex: navIndex,
                username: widget.username,
                onSelect: (i) => setState(() => navIndex = i),
                onLogout: _logout,
              ),
              Expanded(child: content),
            ],
          );
    final body = IndexedStack(
      index: activeTab + 1,
      children: [
        vaultView,
        // 终端 child 结构对 compact 恒定（Column + Expanded）：
        // 旋转/分屏跨断点时仅属性变化，State 复用 → SSH 会话不断（P1-6）
        for (final t in tabs)
          Column(
            children: [
              Expanded(
                child: TerminalTabView(
                  key: t.key,
                  host: t.host,
                  terminal: t.terminal,
                  authKind: t.authKind,
                  secret: t.secret,
                ),
              ),
              // 手机：标签条吸底（Termius 式 ←/标签/+）；终端满幅无深色标题栏
              if (compact)
                _MobileTabBar(
                  tabs: tabs,
                  activeTab: activeTab,
                  onSelectVault: () => setState(() => activeTab = -1),
                  onSelectTab: (i) => setState(() => activeTab = i),
                  onCloseTab: closeTab,
                  onAdd: () => setState(() => activeTab = -1),
                ),
            ],
          ),
      ],
    );
    // 顶部结构（Android 状态栏避让的正确层级）：
    // - 桌面：深色标题栏背景延伸到状态栏区（SafeArea 推内容行），图标 light
    // - 手机：无深色标题栏（账号入口在各页 app bar），浅色状态栏 dark 图标；
    //   终端视图由 TerminalTabView 自带深色状态栏区（内部 SafeArea，light 图标）
    return PopScope<Object?>(
      canPop: activeTab == -1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && activeTab >= 0) setState(() => activeTab = -1);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: compact && activeTab >= 0
          ? SystemUiOverlayStyle.light // 手机终端：深色状态栏区
          : SystemUiOverlayStyle.dark, // 手机列表浅色 / 桌面无状态栏
      child: Scaffold(
      backgroundColor: Et.contentBg,
      body: Column(
        children: [
          if (!compact) ...[
            _TitleBar(
              username: widget.username,
              tabs: tabs,
              activeTab: activeTab,
              onSelectVault: () => setState(() => activeTab = -1),
              onSelectTab: (i) => setState(() => activeTab = i),
              onCloseTab: closeTab,
              onLogout: _logout,
            ),
            if (widget.app.loading)
              const LinearProgressIndicator(minHeight: 2, color: Et.accent),
          ],
          Expanded(child: body),
        ],
      ),
      ),
      ),
    );
  }
}

// ---------- 窄屏底部导航 ----------

/// 手机底栏只收纳有实质功能的页（与侧栏 navIndex 对应：0/1/3/5）。
const _compactNav = [
  (Icons.dns_outlined, 'Hosts'),
  (Icons.key_outlined, 'Keys'),
  (Icons.code, 'Snippets'),
  (Icons.history, 'Logs'),
];
const _compactNavTarget = [0, 1, 3, 5];

int _compactNavIndex(int navIndex) {
  final i = _compactNavTarget.indexOf(navIndex);
  return i < 0 ? 0 : i;
}

// ---------- 手机终端标签条（吸底，Termius 式） ----------

class _MobileTabBar extends StatelessWidget {
  const _MobileTabBar({
    required this.tabs,
    required this.activeTab,
    required this.onSelectVault,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onAdd,
  });

  final List<_TerminalTab> tabs;
  final int activeTab;
  final VoidCallback onSelectVault;
  final void Function(int) onSelectTab;
  final void Function(int) onCloseTab;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    // 手势条避让：键盘弹出时归零（标签条贴键盘，不留空隙）
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom > 0
        ? 0.0
        : MediaQuery.paddingOf(context).bottom;
    return Container(
      height: 52 + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      color: Et.mBg,
      child: Row(
        children: [
          // 返回 vault 列表
          IconButton(
            onPressed: onSelectVault,
            icon: const Icon(Icons.arrow_back_ios_new, size: 19),
            color: Et.textPrimary,
            tooltip: '返回列表',
          ),
          // 标签 pills（横向滚动）
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _pill(context, i),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 24),
            color: Et.textPrimary,
            tooltip: '新建连接',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, int i) {
    final active = activeTab == i;
    return InkWell(
      onTap: () => onSelectTab(i),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 36,
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
        decoration: BoxDecoration(
          color: active ? Et.mSelected : Colors.white.withAlpha(160),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(tabs[i].host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: Et.textPrimary)),
            ),
            const SizedBox(width: 5),
            InkWell(
              onTap: () => onCloseTab(i),
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: Et.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 标题栏 ----------

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.username,
    required this.tabs,
    required this.activeTab,
    required this.onSelectVault,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onLogout,
  });

  final String username;
  final List<_TerminalTab> tabs;
  final int activeTab;
  final VoidCallback onSelectVault;
  final void Function(int) onSelectTab;
  final void Function(int) onCloseTab;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    // 深色背景延伸到状态栏区（SafeArea 把内容行推到状态栏下方），视觉连续
    return Container(
      color: Et.titleBar,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: DragToMoveArea(
        child: Row(
          children: [
            const SizedBox(width: 78), // 交通灯让位区
            _VaultPill(username: username, onLogout: onLogout, onSelectVault: onSelectVault),
            const SizedBox(width: 10),
            // 标签区：多了横向滚动，不挤溢通知钮
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      _TermTabPill(
                        label: tabs[i].host.label,
                        active: activeTab == i,
                        onTap: () => onSelectTab(i),
                        onClose: () => onCloseTab(i),
                        maxLabelWidth: 160,
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.notifications_none,
                  color: Color(0xFF9AA1B0), size: 20),
              tooltip: '通知（M1）',
              onPressed: () {},
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
        ),
      ),
    );
  }
}

class _VaultPill extends StatelessWidget {
  const _VaultPill({
    required this.username,
    required this.onLogout,
    required this.onSelectVault,
  });
  final String username;
  final VoidCallback onLogout;
  final VoidCallback onSelectVault;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);
    showMenu<String>(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy + box.size.height, pos.dx + box.size.width, 0),
      items: [
        PopupMenuItem(enabled: false, child: Text('已登录：$username')),
        const PopupMenuItem(value: 'logout', child: Text('退出登录')),
      ],
    ).then((v) {
      if (v == 'logout') onLogout();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: Et.titleBarPill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 胶囊本体：回到 vault 列表视图（终端标签激活时的返回途径）
          Material(
            color: Colors.transparent,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
            child: InkWell(
              onTap: onSelectVault,
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(9)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.dns, size: 16, color: Et.titleBarText),
                    SizedBox(width: 7),
                    Text('Vaults',
                        style: TextStyle(
                            color: Et.titleBarText,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          // chevron：账户菜单
          Material(
            color: Colors.transparent,
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(9)),
            child: InkWell(
              onTap: () => _showMenu(context),
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(9)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Icon(Icons.keyboard_arrow_down,
                    size: 16, color: Color(0xFF9AA1B0)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TermTabPill extends StatelessWidget {
  const _TermTabPill({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.maxLabelWidth = 160,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? Et.titleBarTabActive : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal, size: 15, color: Et.titleBarText.withAlpha(active ? 255 : 130)),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabelWidth),
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Et.titleBarText.withAlpha(active ? 255 : 150),
                          fontSize: 13)),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close,
                        size: 14, color: Et.titleBarText.withAlpha(140)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 侧边导航 ----------

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.navIndex,
    required this.username,
    required this.onSelect,
    required this.onLogout,
  });

  final int navIndex;
  final String username;
  final void Function(int) onSelect;
  final VoidCallback onLogout;

  static const _items = [
    (Icons.dns_outlined, 'Hosts'),
    (Icons.key_outlined, 'Keychain'),
    (Icons.compare_arrows, 'Port Forwarding'),
    (Icons.code, 'Snippets'),
    (Icons.fingerprint, 'Known Hosts'),
    (Icons.history, 'Logs'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      color: Et.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          for (final (i, (icon, label)) in _items.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Material(
                color: navIndex == i ? Et.sidebarSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onSelect(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    child: Row(
                      children: [
                        Icon(icon,
                            size: 18,
                            color: navIndex == i
                                ? Et.textPrimary
                                : Et.textSecondary),
                        const SizedBox(width: 11),
                        Text(label,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: navIndex == i
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: navIndex == i
                                    ? Et.textPrimary
                                    : Et.textSecondary)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('eterm · $username',
                style: const TextStyle(
                    fontSize: 11.5, color: Et.textSecondary)),
          ),
        ],
      ),
    );
  }
}
