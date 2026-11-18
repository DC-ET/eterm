// 设置页（任务清单 #3）：外观（浅色/深色/跟随系统）、终端字号、辅助键条重排、关于。
// 主题切换经 ThemeController（全局重建，Et 令牌 + Material 同源）；字号即改即存。
// 账户区（登录信息/修改密码/退出登录）在任务清单 #5 落位于此。

import 'package:material_ui/material_ui.dart';

import 'terminal_gestures.dart';
import 'terminal_tab.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final body = ListView(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 24, compact ? 8 : 18,
          compact ? 16 : 24, 24),
      children: [
        if (!compact)
          Text('Settings',
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Et.textPrimary)),
        if (!compact) const SizedBox(height: 12),
        _sectionTitle('外观'),
        // 勿加 const：主题重建时 const 实例会被 Flutter 跳过
        _card(child: _ThemeModePicker()),
        const SizedBox(height: 20),
        _sectionTitle('终端'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FontSizeSlider(),
              Divider(height: 24, color: Et.cardBorder),
              _navRow(
                context,
                icon: Icons.swap_vert,
                title: '重排辅助键条',
                subtitle: '自定义终端键条按键顺序',
                onTap: () => showExtraKeysOrderSheet(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('关于'),
        _card(
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/icon/icon-1024.png',
                    width: 44, height: 44, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('eterm',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Et.textPrimary)),
                    const SizedBox(height: 2),
                    Text('服务器信息与密钥的统一中枢 · 数据面直连目标主机',
                        style: TextStyle(
                            fontSize: 12.5, color: Et.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return body;
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 0, 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Et.textSecondary,
                letterSpacing: 0.3)),
      );

  Widget _card({required Widget child}) => Material(
        color: Et.card,
        borderRadius: BorderRadius.circular(Et.cardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Et.cardRadius),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Et.cardRadius),
              border: Border.all(color: Et.cardBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: child,
          ),
        ),
      );

  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 20, color: Et.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12.5, color: Et.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 20, color: Et.textSecondary),
            ],
          ),
        ),
      );
}

// ---------- 外观选择 ----------

class _ThemeModePicker extends StatelessWidget {
  const _ThemeModePicker();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        final mode = ThemeController.instance.mode;
        return SegmentedButton<AppThemeMode>(
          segments: const [
            ButtonSegment(
                value: AppThemeMode.light,
                icon: Icon(Icons.light_mode_outlined, size: 18),
                label: Text('浅色')),
            ButtonSegment(
                value: AppThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined, size: 18),
                label: Text('深色')),
            ButtonSegment(
                value: AppThemeMode.system,
                icon: Icon(Icons.brightness_auto_outlined, size: 18),
                label: Text('跟随系统')),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) =>
              ThemeController.instance.setMode(s.first),
        );
      },
    );
  }
}

// ---------- 终端字号 ----------

class _FontSizeSlider extends StatelessWidget {
  const _FontSizeSlider();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: TerminalPrefs.fontSize,
      builder: (context, value, _) {
        final isDefault =
            (value - TerminalPrefs.defaultFontSize).abs() < 0.05;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('终端字体大小',
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const Spacer(),
                Text(value.toStringAsFixed(1),
                    style: TextStyle(
                        fontSize: 13,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                        color: Et.textSecondary)),
                if (!isDefault) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => TerminalPrefs.setFontSize(
                        TerminalPrefs.defaultFontSize),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      child: Text('重置默认',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Et.accent)),
                    ),
                  ),
                ],
              ],
            ),
            Slider(
              value: value,
              min: TerminalPrefs.minFontSize,
              max: TerminalPrefs.maxFontSize,
              divisions:
                  ((TerminalPrefs.maxFontSize - TerminalPrefs.minFontSize) * 2)
                      .round(),
              label: value.toStringAsFixed(1),
              activeColor: Et.accent,
              onChanged: (v) => TerminalPrefs.setFontSize(v, persist: false),
              onChangeEnd: (v) => TerminalPrefs.persistFontSize(),
            ),
            // 等宽预览：所见即所得（终端同字体族）
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Et.termTheme.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Text(
                'root@k7:~\$ ssh admin@10.0.0.12   █',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: value,
                  height: 1.4,
                  color: Et.termTheme.foreground,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('双指捏合终端画面也可调整；所有终端标签即时生效。',
                style: TextStyle(fontSize: 12, color: Et.textSecondary)),
          ],
        );
      },
    );
  }
}
