import 'package:flutter/material.dart';

import '../app.dart';
import '../platform.dart';
import '../theme.dart';
import '../updater.dart';

const appVersion = '0.4.1';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title, style: TextStyle(color: p.muted, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
        ),
        Card(child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(height: 1, indent: 56), children[i]],
        ])),
      ]),
    );

    return ListView(
      padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        const PageHeader(title: '设置'),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pagePad(context)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                section('外观', [
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('主题'),
                    subtitle: Text(isDesktop ? '亮色、暗色，或跟随 Windows 设置' : '亮色、暗色，或跟随系统'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: ValueListenableBuilder<ThemeMode>(
                      valueListenable: ThemeController.instance,
                      builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined, size: 17), label: Text('跟随系统')),
                          ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined, size: 17), label: Text('亮色')),
                          ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined, size: 17), label: Text('暗色')),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) => ThemeController.instance.set(s.first),
                      ),
                    ),
                  ),
                ]),
                section('账号', [
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(App.api.server),
                    subtitle: Text('${App.api.user}${App.api.lan ? ' · 局域网' : ' · 外网'}'),
                    trailing: OutlinedButton.icon(
                      icon: const Icon(Icons.logout_rounded, size: 17),
                      onPressed: () async {
                        await App.api.logout();
                        onLogout();
                      },
                      label: const Text('退出登录'),
                    ),
                  ),
                ]),
                section('播放', [
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('115 视频'),
                    subtitle: Text('本机直连 115 CDN，经内置本地代理播放（最多 2 个连接、分块预读），不占家里上行，拖动后从新位置继续',
                        style: TextStyle(color: p.muted)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.subtitles_outlined),
                    title: const Text('字幕'),
                    subtitle: Text('播放器进度条下方的「字幕」按钮：开关字幕、切换字幕轨、按番号在线搜索字幕', style: TextStyle(color: p.muted)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('记住播放位置'),
                    subtitle: Text('再次打开同一部影片时从上次的位置继续', style: TextStyle(color: p.muted)),
                  ),
                ]),
                if (isDesktop) section('播放器快捷键', [
                  for (final (keys, what) in const [
                    ('空格', '播放 / 暂停'),
                    ('← / →', '后退 / 前进 10 秒（连按合并为一次跳转）'),
                    ('↑ / ↓', '音量'),
                    ('Z（按住）', '3 倍速，松开恢复'),
                    ('X / C', '前进 / 后退 5 秒'),
                    ('F 或 双击画面', '全屏'),
                    ('Esc', '退出全屏 / 返回'),
                  ])
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.keyboard_outlined, size: 20),
                      title: Text(what),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(color: p.raised, border: Border.all(color: p.line), borderRadius: BorderRadius.circular(6)),
                        child: Text(keys, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                      ),
                    ),
                ]),
                section('关于', [
                  FutureBuilder<(String, int)>(
                    future: Updater.current(),
                    builder: (context, snap) => ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text('JavHub ${snap.data?.$1 ?? appVersion}'),
                      subtitle: Text('构建 ${snap.data?.$2 ?? '-'} · ${isDesktop ? 'Windows' : 'Android'} · 新版本由 JavHub 服务器分发',
                          style: TextStyle(color: p.muted)),
                      trailing: FilledButton.tonalIcon(
                        onPressed: () => checkForUpdate(context, quiet: false),
                        icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                        label: const Text('检查更新'),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}
