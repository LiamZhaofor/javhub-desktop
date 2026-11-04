import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../player/player_page.dart';
import '../widgets.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.item, this.onFilter, this.onSearch});

  final LibraryItem item;

  /// Back to the library, filtered by an actress / studio / tag.
  final void Function(String query)? onFilter;

  /// To the search page with this code (查找其它版本).
  final void Function(String code)? onSearch;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  String _plot = '';

  LibraryItem get it => widget.item;

  @override
  void initState() {
    super.initState();
    // the list leaves the plot out; fetch it for this one movie
    unawaited(App.api.libraryItem(it.id).then((full) {
      if (mounted) setState(() => _plot = full.plot);
    }).catchError((_) {}));
  }

  void _play(int i) {
    final PlaySource source;
    if (it.cloud) {
      final src = it.sources.length > i ? it.sources[i] : (it.sources.isEmpty ? '' : it.sources.first);
      if (src.isEmpty) {
        toast(context, '找不到网盘源文件，请先在网页端同步 STRM 片库');
        return;
      }
      final path = src.split('/').map(Uri.encodeComponent).join('/');
      source = PlaySource(url: App.api.url('/play/ol$path', {'mode': 'direct', 'relay': '0'}), cloud: true);
    } else {
      source = PlaySource(url: App.api.media(it.id, it.videos[i]), cloud: false);
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        title: it.videos.length > 1 ? '${it.folder} (${i + 1})' : it.folder,
        code: it.code,
        source: source,
        subtitles: [for (final s in it.subs) (s, App.api.media(it.id, s))],
      ),
    ));
  }

  Widget _link(String text, String query) => ActionChip(
    label: Text(text),
    onPressed: widget.onFilter == null ? null : () => widget.onFilter!(query),
  );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final info = <(String, Widget)>[
      ('番号', SelectableText(it.code)),
      ('发行', Text(it.date.isEmpty ? '-' : it.date)),
      ('演员', it.actors.isEmpty ? const Text('-') : Wrap(spacing: 6, runSpacing: 6, children: [for (final a in it.actors) _link(a, a)])),
      ('片商', it.studio.isEmpty ? const Text('-') : Wrap(children: [_link(it.studio, it.studio)])),
      if (it.series.isNotEmpty) ('系列', Wrap(children: [_link(it.series, it.series)])),
      ('分类', Text([it.category, if (it.leak) '流出/破解', if (it.chineseSub) '中字'].where((s) => s.isNotEmpty).join(' · '))),
      ('位置', Text(it.cloud ? '115 网盘  ${it.sources.isEmpty ? '' : it.sources.first}' : 'NAS 本地 · ${fmtSize(it.size)}')),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(it.folder)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > 900;
            final cover = ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: it.fanart ? 1.5 : 0.7,
                child: NetImage(
                  it.fanart
                      ? App.api.media(it.id, 'fanart.jpg', width: 900, version: it.posterVersion)
                      : (it.poster ? App.api.media(it.id, 'poster.jpg', width: 480, version: it.posterVersion) : ''),
                  fit: BoxFit.cover,
                ),
              ),
            );
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(it.title.isEmpty ? it.code : it.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                for (final (k, v) in info)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 48, child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(k, style: TextStyle(color: hint)))),
                        Expanded(child: v),
                      ],
                    ),
                  ),
                if (it.tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final t in it.tags) _link(t, t)]),
                ],
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < it.videos.length; i++)
                      FilledButton.icon(
                        onPressed: () => _play(i),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(it.videos.length > 1 ? '播放 ${i + 1}' : '播放'),
                      ),
                    OutlinedButton.icon(
                      onPressed: widget.onSearch == null ? null : () => widget.onSearch!(it.code),
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('查找其它版本'),
                    ),
                  ],
                ),
              ],
            );
            return wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: c.maxWidth * 0.52, child: cover),
                    const SizedBox(width: 28),
                    Expanded(child: text),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cover, const SizedBox(height: 20), text]);
          }),
          if (_plot.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('简介', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            SelectableText(_plot, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.6)),
          ],
        ],
      ),
    );
  }
}
