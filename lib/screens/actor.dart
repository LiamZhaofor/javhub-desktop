import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'detail.dart';

/// An actress: her movies in the library, the ones on JavDB that are not (open → search),
/// and 关注.
Future<void> openActor(BuildContext context, String name) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ActorPage(name: name)));

class ActorPage extends StatefulWidget {
  const ActorPage({super.key, required this.name});

  final String name;

  @override
  State<ActorPage> createState() => _ActorPageState();
}

class _ActorPageState extends State<ActorPage> {
  ActorInfo? _info;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);
    try {
      final info = await App.api.actor(widget.name, refresh: refresh);
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _follow() async {
    final info = _info;
    if (info == null) return;
    try {
      await App.api.follow(info.name, !info.followed);
      if (mounted) toast(context, info.followed ? '已取消关注' : '已关注 ${info.name}');
      await _load();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final info = _info;
    final pad = pagePad(context);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final missing = info?.works.where((w) => w.inLibrary == null).toList() ?? const <ActorWork>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(tooltip: '从 JavDB 刷新', onPressed: _loading ? null : () => _load(refresh: true), icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: info == null
          ? (_error != null ? ErrorBox(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
          : CustomScrollView(slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, 8, pad, 4),
                sliver: SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (info.jname.isNotEmpty && info.jname != info.name)
                      Text(info.jname, style: TextStyle(color: p.muted, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(
                      ['片库 ${info.items.length} 部', if (info.aid.isNotEmpty) 'JavDB 作品 ${info.works.length} 部', if (info.updated > 0) '${fmtAgo(info.updated)}更新']
                          .join(' · '),
                      style: TextStyle(color: p.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      info.followed
                          ? FilledButton.tonalIcon(onPressed: _follow, icon: const Icon(Icons.check_rounded, size: 18), label: const Text('已关注'))
                          : FilledButton.icon(onPressed: _follow, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('关注')),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          Shell.filterLibrary(context, info.name);
                        },
                        icon: const Icon(Icons.filter_alt_outlined, size: 18),
                        label: const Text('在片库中筛选'),
                      ),
                    ]),
                    if (info.error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(info.error, style: const TextStyle(color: accent, fontSize: 13)),
                    ] else if (info.note.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(info.note, style: TextStyle(color: p.muted, fontSize: 13)),
                    ],
                    const SizedBox(height: 18),
                    _heading(p, '片库里的 ${info.items.length} 部'),
                  ]),
                ),
              ),
              _grid(pad, [
                for (final it in info.items)
                  PosterTile(
                    image: it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : '',
                    code: it.folder,
                    subtitle: it.shortTitle,
                    badges: [if (it.chineseSub) const Badge2('中字'), if (it.cloud) const Badge2('115', color: badgeBlue)],
                    corner: markBadges(it),
                    onTap: () => openDetail(context, it).then((_) => _load()),
                  ),
              ]),
              if (info.aid.isNotEmpty) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 24, pad, 0),
                  sliver: SliverToBoxAdapter(child: _heading(p, '还没有的 ${missing.length} 部', '点开去搜索下载')),
                ),
                _grid(pad, [
                  for (final w in missing)
                    PosterTile(
                      image: App.api.image(w.cover),
                      code: w.code,
                      subtitle: [w.date, w.title].where((s) => s.isNotEmpty).join(' '),
                      cover: true,
                      badges: [
                        if (w.magnet == 'sub') const Badge2('中字磁链'),
                        if (w.date.compareTo(today) > 0) const Badge2('未发售', color: badgeDark) else if (w.wished) const Badge2('想看', color: badgeBlue),
                        if (w.rating > 0) Badge2('★ ${w.rating.toStringAsFixed(1)}', color: badgeDark),
                      ],
                      onTap: () {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                        Shell.search(context, w.code);
                      },
                    ),
                ]),
              ],
              SliverToBoxAdapter(child: SizedBox(height: bottomGap(context))),
            ]),
    );
  }

  Widget _heading(Palette p, String title, [String? sub]) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: p.text)),
      if (sub != null) ...[const SizedBox(width: 8), Text(sub, style: TextStyle(color: p.muted, fontSize: 12))],
    ]),
  );

  Widget _grid(double pad, List<Widget> tiles) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: pad),
    sliver: tiles.isEmpty
        ? SliverToBoxAdapter(child: Text('没有', style: TextStyle(color: Palette.of(context).muted)))
        : SliverGrid.count(
            crossAxisCount: (MediaQuery.sizeOf(context).width / (isCompact(context) ? 130 : 180)).floor().clamp(2, 10),
            mainAxisSpacing: isCompact(context) ? 14 : 20,
            crossAxisSpacing: isCompact(context) ? 10 : 16,
            childAspectRatio: 0.565,
            children: tiles,
          ),
  );
}
