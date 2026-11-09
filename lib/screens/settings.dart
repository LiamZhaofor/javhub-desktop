import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../player/player_page.dart' show seekSteps;
import '../player/settings.dart';
import '../widgets.dart' show NetImage, toast;
import '../theme.dart';
import '../updater.dart';

const appVersion = '0.5.7';

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
      padding: EdgeInsets.only(bottom: bottomGap(context)),
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
                    subtitle: Text(Platform.isWindows ? '亮色、暗色，或跟随 Windows 设置' : '亮色、暗色，或跟随系统'),
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
                  const _AutoSubtitleTile(),
                  const _SeekStepTile(),
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('记住播放位置'),
                    subtitle: Text('再次打开同一部影片时从上次的位置继续', style: TextStyle(color: p.muted)),
                  ),
                ]),
                if (isDesktop) section('播放器快捷键', [
                  for (final (keys, what) in const [
                    ('空格', '播放 / 暂停'),
                    ('← / →', '后退 / 前进（步长见上方「快进 / 快退」，连按合并为一次跳转）'),
                    ('→（按住）', '3 倍速，松开恢复（同 Z）'),
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
                section('已屏蔽的影片', [const _BlockedList()]),
                section('关于', [
                  FutureBuilder<(String, int)>(
                    future: Updater.current(),
                    builder: (context, snap) => ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text('JavHub ${snap.data?.$1 ?? appVersion}'),
                      subtitle: Text('构建 ${snap.data?.$2 ?? '-'} · $platformName · 新版本由 JavHub 服务器分发',
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

/// 设置 → 播放: search online by code when a movie without subtitles starts, and load the first.
class _AutoSubtitleTile extends StatefulWidget {
  const _AutoSubtitleTile();

  @override
  State<_AutoSubtitleTile> createState() => _AutoSubtitleTileState();
}

class _AutoSubtitleTileState extends State<_AutoSubtitleTile> {
  JavPlayerSettings? _s;

  @override
  void initState() {
    super.initState();
    JavPlayerSettings.load().then((s) {
      if (mounted) setState(() => _s = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return SwitchListTile(
      secondary: const Icon(Icons.travel_explore_rounded),
      title: const Text('自动加载在线字幕'),
      subtitle: Text('打开没有自带字幕的影片时，自动按番号搜索并加载第一个（时长吻合的优先）',
          style: TextStyle(color: Palette.of(context).muted)),
      value: s?.autoSubtitle ?? false,
      onChanged: s == null
          ? null
          : (v) async {
              // the player may have changed other settings since: start from the stored ones
              final fresh = await JavPlayerSettings.load();
              fresh.autoSubtitle = v;
              await fresh.save();
              if (mounted) setState(() => _s = fresh);
            },
    );
  }
}

/// 设置 → 已屏蔽的影片: the blocked movies, each with 取消屏蔽.
class _BlockedList extends StatefulWidget {
  const _BlockedList();

  @override
  State<_BlockedList> createState() => _BlockedListState();
}

class _BlockedListState extends State<_BlockedList> {
  List<BlockedMovie>? _items;
  String? _error;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await App.api.blocked();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _unblock(BlockedMovie b) async {
    try {
      await App.api.block(b.code, false);
      if (!mounted) return;
      setState(() => _items = [...?_items]..remove(b));
      toast(context, '已取消屏蔽 ${b.code}');
      Shell.refresh();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final items = _items;
    if (items == null) {
      return ListTile(
        leading: const Icon(Icons.block_rounded),
        title: Text(_error ?? '加载中…', style: TextStyle(color: _error == null ? p.muted : accent)),
      );
    }
    if (items.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.block_rounded),
        title: const Text('没有屏蔽的影片'),
        subtitle: Text('影片页右上角 ⋯ → 屏蔽，或搜索结果里的「屏蔽」', style: TextStyle(color: p.muted)),
      );
    }
    final shown = _expanded ? items : items.take(5).toList();
    return Column(children: [
      for (final b in shown)
        ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              width: 36,
              height: 52,
              child: NetImage(
                b.item != null && b.poster
                    ? App.api.media(b.item!, 'poster.jpg', width: 240, version: b.posterVersion)
                    : (b.cover.isEmpty ? '' : App.api.image(b.cover)),
                decodeWidth: 120,
                alignment: Alignment.centerRight,
                poster: true,
              ),
            ),
          ),
          title: Text(b.code, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: b.title.isEmpty ? null : Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted)),
          trailing: OutlinedButton(onPressed: () => _unblock(b), child: const Text('取消屏蔽')),
        ),
      if (items.length > shown.length)
        TextButton(onPressed: () => setState(() => _expanded = true), child: Text('显示全部 ${items.length} 部')),
    ]);
  }
}

/// 设置 → 播放: how far ← / →, the bar's buttons and a double tap jump.
class _SeekStepTile extends StatefulWidget {
  const _SeekStepTile();

  @override
  State<_SeekStepTile> createState() => _SeekStepTileState();
}

class _SeekStepTileState extends State<_SeekStepTile> {
  double? _step;

  @override
  void initState() {
    super.initState();
    JavPlayerSettings.load().then((s) {
      if (mounted) setState(() => _step = s.seekStep);
    });
  }

  Future<void> _set(double v) async {
    final s = await JavPlayerSettings.load();
    s.seekStep = v;
    await s.save();
    if (mounted) setState(() => _step = v);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    ListTile(
      leading: const Icon(Icons.fast_forward_rounded),
      title: const Text('快进 / 快退'),
      subtitle: Text(isDesktop ? '← / → 键、进度条旁的按钮每次跳多少秒' : '双击屏幕左右两侧每次跳多少秒', style: TextStyle(color: Palette.of(context).muted)),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: SegmentedButton<double>(
        showSelectedIcon: false,
        segments: [for (final s in seekSteps) ButtonSegment(value: s, label: Text('${s.toInt()} 秒'))],
        selected: {_step ?? 10},
        onSelectionChanged: _step == null ? null : (v) => _set(v.first),
      ),
    ),
  ]);
}
