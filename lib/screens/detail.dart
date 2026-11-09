import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../models.dart';
import '../motion.dart';
import '../platform.dart';
import '../player/player_page.dart';
import '../player/player_window.dart';
import '../player/stream_proxy.dart';
import '../widgets.dart';
import 'actor.dart';

/// Opens a movie's page; its actress / tag links filter the library, 查找其它版本 searches.
Future<void> openDetail(BuildContext context, LibraryItem it, {Object? heroTag}) => Navigator.of(context).push(MaterialPageRoute(
  builder: (route) => DetailPage(
    item: it,
    heroTag: heroTag,
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
  const DetailPage({super.key, required this.item, this.onFilter, this.onSearch, this.heroTag});

  final LibraryItem item;

  /// The tile it was opened from: its poster flies into this page's cover.
  final Object? heroTag;

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
  Map<int, Progress> _progress = const {};

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
    unawaited(_loadProgress());
    // the seek-bar previews take a minute to make: start now, before 播放
    unawaited(App.api.trickplay(it.id).then((_) {}).catchError((_) {}));
    // a 115 movie: the link and the file's start and end (its index) while the
    // page is read, so 播放 starts at once (on a phone away from home: the link only)
    final cloud = _cloudUrl(0);
    if (cloud != null) JavStreamProxy.instance.prepare(cloud, headers: App.api.authHeaders, tail: isDesktop || App.api.lan);
  }

  /// JavHub's 115 route for part [i]; null when it has no 115 source.
  String? _cloudUrl(int i) {
    if (!it.cloud) return null;
    final src = it.sources.length > i ? it.sources[i] : (it.sources.isEmpty ? '' : it.sources.first);
    if (src.isEmpty) return null;
    final path = src.split('/').map(Uri.encodeComponent).join('/');
    return App.api.url('/play/ol$path', {'mode': 'direct', 'relay': '0'});
  }

  Future<void> _loadProgress() async {
    try {
      final p = await App.api.progress(it.id);
      if (mounted) setState(() => _progress = p);
    } catch (_) {}
  }

  String _still(String name, {int? width}) => App.api.media(it.id, 'extrafanart/$name', width: width, version: it.posterVersion);

  void _showStills(int start) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (_) => _StillViewer(urls: [for (final s in _stills) _still(s)], start: start),
  );

  bool _opening = false;

  void _play(int i, {bool resume = true}) {
    final PlaySource source;
    if (it.cloud) {
      final url = _cloudUrl(i);
      if (url == null) {
        toast(context, '找不到网盘源文件，请先在网页端同步 STRM 片库');
        return;
      }
      source = PlaySource(url: url, cloud: true);
    } else {
      source = PlaySource(url: App.api.media(it.id, it.videos[i]), cloud: false);
    }
    if (isDesktop) {
      unawaited(_playInWindow(i, source, resume));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        title: it.videos.length > 1 ? '${it.folder} (${i + 1})' : it.folder,
        code: it.code,
        itemId: it.id,
        part: i,
        resume: resume,
        source: source,
        subtitles: [for (final s in it.subs) (s, App.api.media(it.id, s))],
      ),
    )).then((_) => Future<void>.delayed(const Duration(milliseconds: 600), _loadProgress));
  }

  /// Windows: the movie plays in a window of its own. The stream is got ready here
  /// (this window prepared it while the page was read) and handed over as a
  /// loopback address, with where to start.
  Future<void> _playInWindow(int i, PlaySource source, bool resume) async {
    if (_opening || PlayerWindows.focus(it.id, i)) return;
    setState(() => _opening = true);
    try {
      final title = it.videos.length > 1 ? '${it.folder} (${i + 1})' : it.folder;
      final start = resumePosition(itemId: it.id, part: i, url: source.url, resume: resume);
      var play = source;
      if (source.cloud) {
        final local = await JavStreamProxy.instance.wrap(source.url, headers: App.api.authHeaders);
        if (local != source.url) play = PlaySource(url: local, cloud: true, local: true);
      }
      final (pos, from) = await start;
      final bounds = await windowManager.getBounds();
      final maximized = await windowManager.isMaximized();
      await PlayerWindows.open(
        PlayerArgs(
          title: title,
          code: it.code,
          itemId: it.id,
          part: i,
          source: play,
          subtitles: [for (final s in it.subs) (s, App.api.media(it.id, s))],
          start: pos,
          from: from,
          lanBase: App.api.lanBase,
          bounds: bounds,
          maximized: maximized,
        ),
        onClosed: () {
          Future<void>.delayed(const Duration(milliseconds: 600), () {
            if (mounted) unawaited(_loadProgress());
            Shell.refresh();
          });
        },
      );
    } catch (e) {
      if (mounted) toast(context, '无法打开播放窗口: $e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _chip(String text, {IconData? icon, VoidCallback? onTap}) => ActionChip(
    avatar: icon == null ? null : Icon(icon, size: 15),
    label: Text(text),
    onPressed: onTap ?? (widget.onFilter == null ? null : () => widget.onFilter!(text)),
  );

  // ---------------- marks ----------------
  Future<void> _mark(Map<String, Object?> patch) async {
    try {
      final m = await App.api.setMark(it.code, patch);
      if (mounted) setState(() => it.applyMarks(m));
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Widget _marks(Palette p) => Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
    it.fav
        ? FilledButton.tonalIcon(
            onPressed: () => _mark({'fav': false}),
            icon: const Icon(Icons.favorite_rounded, color: accent, size: 18),
            label: const Text('已收藏'),
          )
        : OutlinedButton.icon(onPressed: () => _mark({'fav': true}), icon: const Icon(Icons.favorite_border_rounded, size: 18), label: const Text('收藏')),
    Tooltip(
      message: '我的评分（再点一次取消）',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var n = 1; n <= 5; n++)
          InkResponse(
            radius: 18,
            onTap: () => _mark({'rating': n == it.rating ? 0 : n}),
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: Icon(n <= it.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 27, color: n <= it.rating ? const Color(0xFFF5B301) : p.muted),
            ),
          ),
      ]),
    ),
    Tooltip(
      message: it.watchedSet ? '手动标记' : '自动：看到片尾就算看过',
      child: it.watched
          ? FilledButton.tonalIcon(
              onPressed: () => _mark({'watched': false}),
              icon: const Icon(Icons.check_circle_rounded, size: 18),
              label: const Text('已看'),
            )
          : OutlinedButton.icon(onPressed: () => _mark({'watched': true}), icon: const Icon(Icons.visibility_outlined, size: 18), label: const Text('未看')),
    ),
    if (it.watchedSet) TextButton(onPressed: () => _mark({'watched': null}), child: const Text('恢复自动')),
  ]);

  // ---------------- fixing the movie ----------------
  Future<void> _manage(String act) async {
    Object? body;
    if (act == 'recode') {
      final code = await _askCode();
      if (code == null) return;
      body = {'code': code};
    } else if (act == 'block') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('屏蔽 ${it.code}？'),
          content: const Text('它不会再出现在片库、首页、推荐和演员页里。可以在 设置 → 已屏蔽的影片 里取消屏蔽。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('屏蔽')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await App.api.block(it.code, true, item: it.id, title: it.title);
        if (!mounted) return;
        toast(context, '已屏蔽 ${it.code}');
        Shell.refresh();
        Navigator.of(context).maybePop();
      } catch (e) {
        if (mounted) toast(context, '$e');
      }
      return;
    } else if (act == 'to-nas') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('把 ${it.folder} 保存到 NAS？'),
          content: Text('从 115 复制一份到 NAS 片库（${it.sources.map((s) => s.split('/').last).join('、')}），封面和资料一起带过去。'
              '115 上的文件不动。进度在「任务」页。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存到 NAS')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await App.api.manage(it.id, 'to-nas');
        if (mounted) toast(context, '开始从 115 复制到 NAS，进度见「任务」页');
      } catch (e) {
        if (mounted) toast(context, '$e');
      }
      return;
    } else if (act == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('从片库移除 ${it.folder}？'),
          content: Text(it.cloud ? '网盘里的文件不会删除，只是不再出现在片库和 Emby 里，之后同步也不会再加回来。' : '影片文件夹会移到片库的 .trash 目录，需要时可以手动移回。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('移除')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final r = await App.api.manage(it.id, act, body);
      if (!mounted) return;
      toast(context, switch (act) {
        'remove' => '${r['message'] ?? '已移除'}',
        'recode' => '已改为 ${r['code']}，正在重新刮削，几分钟后封面和资料会出现',
        _ => '已清除旧资料，正在重新刮削，几分钟后可见',
      });
      Shell.refresh();
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<String?> _askCode() {
    final c = TextEditingController(text: it.code);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改番号'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${it.folder} 的正确番号，改完会重新刮削', style: TextStyle(color: Palette.of(ctx).muted, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '例如 SSIS-001'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
        ],
      ),
    ).then((v) => v == null || v.isEmpty ? null : v);
  }

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
                  padding: EdgeInsets.fromLTRB(isCompact(context) ? 12 : 20, MediaQuery.paddingOf(context).top + 14, isCompact(context) ? 12 : 32, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        IconButton.filledTonal(
                          tooltip: '返回',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        PopupMenuButton<String>(
                          tooltip: '管理这部影片',
                          icon: const Icon(Icons.more_horiz_rounded),
                          style: IconButton.styleFrom(backgroundColor: p.raised.withValues(alpha: 0.7)),
                          onSelected: _manage,
                          itemBuilder: (_) => [
                            if (it.cloud)
                              const PopupMenuItem(value: 'to-nas', child: ListTile(leading: Icon(Icons.download_for_offline_rounded), title: Text('保存到 NAS'), subtitle: Text('从 115 复制一份到 NAS 片库'))),
                            const PopupMenuItem(value: 'rescrape', child: ListTile(leading: Icon(Icons.auto_fix_high_rounded), title: Text('重新刮削'), subtitle: Text('清除封面和资料重新获取'))),
                            const PopupMenuItem(value: 'recode', child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('改番号…'), subtitle: Text('番号认错了'))),
                            const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.remove_circle_outline_rounded, color: accent), title: Text('从片库移除'))),
                            const PopupMenuItem(value: 'block', child: ListTile(leading: Icon(Icons.block_rounded), title: Text('屏蔽'), subtitle: Text('不再出现在片库、首页和推荐里'))),
                          ],
                        ),
                      ]),
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
                            child: AspectRatio(
                              aspectRatio: it.fanart ? 1.5 : 0.7,
                              child: widget.heroTag == null
                                  ? NetImage(cover)
                                  : Hero(tag: widget.heroTag!, flightShuttleBuilder: crossFadeShuttle, child: NetImage(cover)),
                            ),
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
                            _marks(p),
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
                              for (var i = 0; i < it.videos.length; i++) ...[
                                FilledButton.icon(
                                  onPressed: _opening ? null : () => _play(i),
                                  icon: _opening
                                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.play_arrow_rounded),
                                  label: Text([
                                    if (_progress[i]?.resumable ?? false) '继续 ${fmtClock(Duration(seconds: _progress[i]!.pos.floor()))}' else '播放',
                                    if (it.videos.length > 1) '${i + 1}',
                                  ].join(' ')),
                                ),
                                if (_progress[i]?.resumable ?? false)
                                  OutlinedButton.icon(
                                    onPressed: () => _play(i, resume: false),
                                    icon: const Icon(Icons.replay_rounded, size: 18),
                                    label: const Text('从头播放'),
                                  ),
                              ],
                              OutlinedButton.icon(
                                onPressed: widget.onSearch == null ? null : () => widget.onSearch!(it.code),
                                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                                label: const Text('查找其它版本'),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            if (it.actors.isNotEmpty) _section('演员', [for (final a in it.actors) _chip(a, icon: Icons.person_outline, onTap: () => openActor(context, a))]),
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
              padding: EdgeInsets.fromLTRB(isCompact(context) ? 12 : 32, 0, isCompact(context) ? 12 : 32, 28),
              sliver: SliverToBoxAdapter(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('剧照', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
                    const SizedBox(width: 8),
                    Text('${_stills.length} 张', style: TextStyle(color: p.muted, fontSize: 12.5)),
                  ]),
                  const SizedBox(height: 10),
                  LayoutBuilder(builder: (context, c) {
                    final cols = (c.maxWidth / (isCompact(context) ? 160 : 230)).floor().clamp(2, 8);
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
              padding: EdgeInsets.fromLTRB(isCompact(context) ? 12 : 32, 0, isCompact(context) ? 12 : 32, 40),
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
    // a dialog has no Material of its own: without one text gets the debug underline
    child: Material(
      type: MaterialType.transparency,
      child: Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: () => Navigator.of(context).pop())),
      PageView.builder(
        controller: _pages,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) => Padding(
          padding: isCompact(context) ? const EdgeInsets.symmetric(vertical: 60) : const EdgeInsets.fromLTRB(80, 60, 80, 60),
          child: InteractiveViewer(child: SizedBox.expand(child: NetImage(widget.urls[i], fit: BoxFit.contain))),
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
    ),
  );
}
