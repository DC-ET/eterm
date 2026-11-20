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
import '../services/fg_service.dart';
import '../services/realtime.dart';
import '../services/app_state.dart';
import 'hosts_page.dart';
import 'keychain_page.dart';
import 'logs_page.dart';
import 'known_hosts_page.dart';
import 'port_forwarding_page.dart';
import 'settings_page.dart';
import 'sftp_entry_page.dart';
import 'sftp_page.dart';
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
  /// 会话阶段（pill 状态点，评审 P2：断连此前无感知）
  final phase = ValueNotifier<TermPhase>(TermPhase.connecting);
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
    FgService.setKeepAlive(tabs.isNotEmpty); // 前台服务保活 SSH（M1）
  }

  /// 主机卡片菜单「SFTP 文件」：host ⇄ 本机 直达双侧页（凭据与终端同一解析链）。
  void _openSftpFor(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机还没有凭据，请通过卡片菜单「编辑主机」补充')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SftpDualPage(
        left: SftpSideSpec(host: h, authKind: cred.authKind, secret: cred.secret),
        right: const SftpSideSpec(), // 本机
      ),
    ));
  }

  void closeTab(int i) {
    setState(() {
      tabs.removeAt(i);
      // phase notifier 不在这里 dispose：TerminalTabView State 帧末才销毁，
      // 期间 SSH 事件仍可能经 onPhase 回写（复审必修 A：use-after-dispose）。
      // ValueListenableBuilder unmount 自行解绑，无监听的 notifier 交给 GC。
      if (tabs.isEmpty) {
        activeTab = -1;
      } else if (i < activeTab) {
        activeTab -= 1; // 评审 BUG-D2 回归：关闭左侧标签后仍查看同一会话
      } else if (activeTab >= tabs.length) {
        activeTab = tabs.length - 1;
      }
    });
    FgService.setKeepAlive(tabs.isNotEmpty);
  }

  Future<void> _logout() async {
    realtime.stop();
    FgService.setKeepAlive(false);
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
    realtime.stop();
    FgService.setKeepAlive(false);
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
    // 注册 Theme 依赖：主题切换时整个壳（含各导航页）随之重建
    // （Et 是静态令牌，自身不感知 inherited；无此依赖 pushed 路由不会重绘）
    Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 720; // 手机竖屏
    final content = switch (navIndex) {
      0 => HostsPage(
          app: widget.app,
          onOpenTerminal: openTerminal,
          openHostIds: {for (final t in tabs) t.host.id},
          onOpenSettings: () => setState(() => navIndex = 6),
          onOpenSftp: _openSftpFor,
        ),
      1 => SftpEntryPage(app: widget.app),
      2 => KeychainPage(app: widget.app),
      3 => PortForwardingPage(app: widget.app),
      // 勿加 const：Shell 随主题重建时 const 实例会被 Flutter 跳过（identical）
      4 => KnownHostsPage(),
      5 => LogsPage(),
      6 => SettingsPage(
          app: widget.app,
          username: widget.username,
          onLogout: _logout),
      _ => _MorePage(onNavigate: (i) => setState(() => navIndex = i)),
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
                onSelect: (i) => setState(() => navIndex = i),
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
              onPhase: (p) => t.phase.value = p, // pill 状态点同步
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
      value: compact && activeTab >= 0 || Et.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light // 手机终端深色区 / 深色主题
          : SystemUiOverlayStyle.dark, // 浅色列表页 / 桌面无状态栏
      child: Scaffold(
      backgroundColor: Et.contentBg,
      body: Column(
        children: [
          if (!compact) ...[
            _TitleBar(
              tabs: tabs,
              activeTab: activeTab,
              onSelectVault: () => setState(() => activeTab = -1),
              onSelectTab: (i) => setState(() => activeTab = i),
              onCloseTab: closeTab,
            ),
            // 加载条常驻 2px 槽位：同步开始/结束只切换槽位内容，不插入/移除节点，
            // 进度条出现时不会把下方内容顶下去（否则画面跟着抖一下）
            SizedBox(
              height: 2,
              child: widget.app.loading
                  ? LinearProgressIndicator(minHeight: 2, color: Et.accent)
                  : null,
            ),
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

/// 手机底栏收纳全部实页，与侧栏 navIndex 对应：0/1/3/4。
/// 评审 BUG-D1 回归：Known Hosts（侧栏 3）必须有手机入口，否则 compact 布局不可达。
const _compactNav = [
  (Icons.dns_outlined, 'Hosts'),
  (Icons.folder_copy_outlined, 'SFTP'),
  (Icons.key_outlined, 'Keychain'),
  (Icons.apps, 'More'),
];
const _compactNavTarget = [0, 1, 2, -1]; // -1 = More 页（占位 navIndex）

int _compactNavIndex(int navIndex) {
  if (navIndex == -1) return 3; // More 页
  final i = _compactNavTarget.indexOf(navIndex);
  if (i >= 0) return i;
  return 3; // 经 More 进入的实页（navIndex 3-6）：底栏高亮 More
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
          color: active
                  ? Et.mSelected
                  : (Et.brightness == Brightness.dark
                      ? Colors.white.withAlpha(24)
                      : Colors.white.withAlpha(160)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 会话状态点（评审 P2：连接中/已连接/断开 可感知）
            ValueListenableBuilder<TermPhase>(
              valueListenable: tabs[i].phase,
              builder: (context, ph, _) => Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (ph) {
                    TermPhase.live => const Color(0xFF2DA44E),
                    TermPhase.connecting => Et.textSecondary,
                    TermPhase.closed => Et.danger,
                  },
                ),
              ),
            ),
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
            // 关闭按钮：命中区扩到 ~34px（评审 P1：此前约 23px，触屏难点中）
            InkWell(
              onTap: () => onCloseTab(i),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Icon(Icons.close,
                    size: 15, color: Et.textSecondary),
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
    required this.tabs,
    required this.activeTab,
    required this.onSelectVault,
    required this.onSelectTab,
    required this.onCloseTab,
  });

  final List<_TerminalTab> tabs;
  final int activeTab;
  final VoidCallback onSelectVault;
  final void Function(int) onSelectTab;
  final void Function(int) onCloseTab;

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
            _VaultPill(onSelectVault: onSelectVault),
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
                        phase: tabs[i].phase,
                        onTap: () => onSelectTab(i),
                        onClose: () => onCloseTab(i),
                        maxLabelWidth: 160,
                      ),
                  ],
                ),
              ),
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
  const _VaultPill({required this.onSelectVault});
  final VoidCallback onSelectVault;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: Et.titleBarPill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onSelectVault,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
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
    );
  }
}

class _TermTabPill extends StatelessWidget {
  const _TermTabPill({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.phase,
    this.maxLabelWidth = 160,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueNotifier<TermPhase>? phase; // 会话状态点（null 不显示）
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
                if (phase != null) ...[
                  const SizedBox(width: 6),
                  // 会话状态点（评审 P2：断连此前无感知）
                  ValueListenableBuilder<TermPhase>(
                    valueListenable: phase!,
                    builder: (context, ph, _) => Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: switch (ph) {
                          TermPhase.live => const Color(0xFF2DA44E),
                          TermPhase.connecting =>
                            Et.titleBarText.withAlpha(150),
                          TermPhase.closed => Et.danger,
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                // 关闭按钮：命中区扩到 ~26px（评审 P1）
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: Center(
                      child: Icon(Icons.close,
                          size: 14, color: Et.titleBarText.withAlpha(140)),
                    ),
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
    required this.onSelect,
  });

  final int navIndex;
  final void Function(int) onSelect;

  static const _items = [
    (Icons.dns_outlined, 'Hosts'),
    (Icons.folder_copy_outlined, 'SFTP'),
    (Icons.key_outlined, 'Keychain'),
    (Icons.compare_arrows, 'Port Forwarding'),
    (Icons.fingerprint, 'Known Hosts'),
    (Icons.history, 'Logs'),
    (Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      color: Et.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌行
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icon/icon-1024.png',
                      width: 24, height: 24, fit: BoxFit.cover),
                ),
                const SizedBox(width: 9),
                Text('Eterm',
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Et.textPrimary,
                        letterSpacing: 0.2)),
              ],
            ),
          ),
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
            child: Text('Eterm',
                style: TextStyle(
                    fontSize: 11.5, color: Et.textSecondary)),
          ),
        ],
      ),
    );
  }
}


// ---------- 手机「更多」页（Port Forwarding / Known Hosts / Logs / Settings 入口） ----------

class _MorePage extends StatelessWidget {
  const _MorePage({required this.onNavigate});

  final void Function(int) onNavigate;

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('More',
            style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        const SizedBox(height: 12),
        _row(context, Icons.compare_arrows, 'Port Forwarding', '本地 -L 端口转发规则',
            () => onNavigate(3)),
        _row(context, Icons.fingerprint, 'Known Hosts', 'TOFU 主机指纹记录',
            () => onNavigate(4)),
        _row(context, Icons.history, 'Logs', '连接与同步事件',
            () => onNavigate(5)),
        _row(context, Icons.settings_outlined, 'Settings', '账号 / 外观 / 终端字号',
            () => onNavigate(6)),
      ],
    );
  }

  Widget _row(BuildContext context, IconData icon, String title, String sub,
      VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Et.card,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Et.sidebarSelected,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Et.textPrimary, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              color: Et.textPrimary)),
                      const SizedBox(height: 3),
                      Text(sub,
                          style: TextStyle(
                              fontSize: 13, color: Et.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20, color: Et.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
