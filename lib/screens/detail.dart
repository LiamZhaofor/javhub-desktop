import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models.dart';
import '../player/player_page.dart';
import '../widgets.dart';

/// Opens a movie's page; its actress / tag links filter the library, 查找其它版本 searches.
Future<void> openDetail(BuildContext context, LibraryItem it) => Navigator.of(context).push(MaterialPageRoute(
  builder: (route) => DetailPage(
    item: it,
    onFilter: (q) {
      Navigator.of(route).pop();
      Shell.filterLibrary(context, q);
    },
    onSearch: (code) {
      Navigator.of(route).pop();
      Shell.search(context, code);
    },
  ),
));

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
  List<String> _stills = const [];

  LibraryItem get it => widget.item;

  @override
  void initState() {
    super.initState();
    // the list leaves the plot and the stills out; fetch them for this one movie
    unawaited(App.api.libraryItem(it.id).then((full) {
      if (mounted) {
        setState(() {
          _plot = full.plot;
          _stills = full.stills;
        });
      }
    }).catchError((_) {}));
    // the seek-bar previews take a minute to make: start now, before 播放
    unawaited(App.api.trickplay(it.id).then((_) {}).catchError((_) {}));
  }

  String _still(String name, {int? width}) => App.api.media(it.id, 'extrafanart/$name', width: width, version: it.posterVersion);

  void _showStills(int start) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (_) => _StillViewer(urls: [for (final s in _stills) _still(s)], start: start),
  );

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
        itemId: it.id,
        source: source,
        subtitles: [for (final s in it.subs) (s, App.api.media(it.id, s))],
      ),
    ));
  }

  Widget _chip(String text, {IconData? icon}) => ActionChip(
    avatar: icon == null ? null : Icon(icon, size: 15),
    label: Text(text),
    onPressed: widget.onFilter == null ? null : () => widget.onFilter!(text),
  );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cover = it.fanart
        ? App.api.media(it.id, 'fanart.jpg', width: 900, version: it.posterVersion)
        : (it.poster ? App.api.media(it.id, 'poster.jpg', width: 480, version: it.posterVersion) : '');
    final facts = <(IconData, String)>[
      if (it.date.isNotEmpty) (Icons.event_outlined, it.date),
      if (it.category.isNotEmpty) (Icons.category_outlined, [it.category, if (it.leak) '流出'].join(' · ')),
      if (it.chineseSub) (Icons.subtitles_outlined, '中文字幕'),
      it.cloud ? (Icons.cloud_outlined, '115 网盘') : (Icons.storage_outlined, 'NAS · ${fmtSize(it.size)}'),
    ];
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                // blurred artwork behind the header, fading into the page
                Positioned.fill(
                  child: ClipRect(
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                      child: Opacity(opacity: dark ? 0.55 : 0.35, child: NetImage(cover, decodeWidth: 300)),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [p.bg.withValues(alpha: 0.35), p.bg],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 32, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconButton.filledTonal(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(builder: (context, c) {
                        final wide = c.maxWidth > 920;
                        final art = Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 12))],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: AspectRatio(aspectRatio: it.fanart ? 1.5 : 0.7, child: NetImage(cover)),
                          ),
                        );
                        final info = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(it.code, style: const TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 0.5)),
                            const SizedBox(height: 6),
                            SelectableText(it.title.isEmpty ? it.code : it.title,
                                style: TextStyle(fontSize: 22, height: 1.35, fontWeight: FontWeight.w800, color: p.text)),
                            const SizedBox(height: 14),
                            Wrap(spacing: 16, runSpacing: 8, children: [
                              for (final (icon, text) in facts)
                                Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(icon, size: 16, color: p.muted),
                                  const SizedBox(width: 5),
                                  Text(text, style: TextStyle(color: p.muted)),
                                ]),
                            ]),
                            const SizedBox(height: 22),
                            Wrap(spacing: 10, runSpacing: 10, children: [
                              for (var i = 0; i < it.videos.length; i++)
                                FilledButton.icon(
                                  onPressed: () => _play(i),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: Text(it.videos.length > 1 ? '播放 ${i + 1}' : '播放'),
                                ),
                              OutlinedButton.icon(
                                onPressed: widget.onSearch == null ? null : () => widget.onSearch!(it.code),
                                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                                label: const Text('查找其它版本'),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            if (it.actors.isNotEmpty) _section('演员', [for (final a in it.actors) _chip(a, icon: Icons.person_outline)]),
                            if (it.studio.isNotEmpty || it.series.isNotEmpty)
                              _section('片商 / 系列', [if (it.studio.isNotEmpty) _chip(it.studio), if (it.series.isNotEmpty) _chip(it.series)]),
                            if (it.tags.isNotEmpty) _section('标签', [for (final t in it.tags) _chip(t)]),
                          ],
                        );
                        return wide
                            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SizedBox(width: c.maxWidth * 0.5, child: art),
                                const SizedBox(width: 32),
                                Expanded(child: info),
                              ])
                            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [art, const SizedBox(height: 22), info]);
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_stills.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              sliver: SliverToBoxAdapter(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('剧照', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
                    const SizedBox(width: 8),
                    Text('${_stills.length} 张', style: TextStyle(color: p.muted, fontSize: 12.5)),
                  ]),
                  const SizedBox(height: 10),
                  LayoutBuilder(builder: (context, c) {
                    final cols = (c.maxWidth / 230).floor().clamp(2, 8);
                    final w = (c.maxWidth - (cols - 1) * 10) / cols;
                    return Wrap(spacing: 10, runSpacing: 10, children: [
                      for (var i = 0; i < _stills.length; i++)
                        _StillThumb(url: _still(_stills[i], width: 360), width: w, onTap: () => _showStills(i)),
                    ]);
                  }),
                ]),
              ),
            ),
          if (_plot.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
              sliver: SliverToBoxAdapter(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('简介', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
                  const SizedBox(height: 8),
                  SelectableText(_plot, style: TextStyle(color: p.muted, height: 1.75, fontSize: 14)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> chips) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: Palette.of(context).muted, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: chips),
    ]),
  );
}

class _StillThumb extends StatefulWidget {
  const _StillThumb({required this.url, required this.width, required this.onTap});

  final String url;
  final double width;
  final VoidCallback onTap;

  @override
  State<_StillThumb> createState() => _StillThumbState();
}

class _StillThumbState extends State<_StillThumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.zoomIn,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: widget.width,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _hover ? accent : Palette.of(context).line, width: _hover ? 1.5 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: AspectRatio(aspectRatio: 3 / 2, child: NetImage(widget.url, decodeWidth: 360)),
        ),
      ),
    ),
  );
}

/// Full-size stills, one at a time: arrows / keys to page, Esc or a click outside to close.
class _StillViewer extends StatefulWidget {
  const _StillViewer({required this.urls, required this.start});

  final List<String> urls;
  final int start;

  @override
  State<_StillViewer> createState() => _StillViewerState();
}

class _StillViewerState extends State<_StillViewer> {
  late final _pages = PageController(initialPage: widget.start);
  late int _i = widget.start;

  void _go(int d) {
    final n = (_i + d).clamp(0, widget.urls.length - 1);
    unawaited(_pages.animateToPage(n, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) {
      if (e is! KeyDownEvent) return KeyEventResult.ignored;
      if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _go(-1);
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
        _go(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: () => Navigator.of(context).pop())),
      PageView.builder(
        controller: _pages,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.fromLTRB(80, 60, 80, 60),
          child: InteractiveViewer(child: Center(child: NetImage(widget.urls[i], fit: BoxFit.contain))),
        ),
      ),
      Positioned(
        top: 16,
        right: 16,
        child: IconButton.filledTonal(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
      ),
      Positioned(
        top: 24,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Text('${_i + 1} / ${widget.urls.length}', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
      if (_i > 0)
        Positioned(
          left: 16,
          top: 0,
          bottom: 0,
          child: Center(child: IconButton.filledTonal(iconSize: 30, onPressed: () => _go(-1), icon: const Icon(Icons.chevron_left_rounded))),
        ),
      if (_i < widget.urls.length - 1)
        Positioned(
          right: 16,
          top: 0,
          bottom: 0,
          child: Center(child: IconButton.filledTonal(iconSize: 30, onPressed: () => _go(1), icon: const Icon(Icons.chevron_right_rounded))),
        ),
    ]),
  );
}
