import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../models.dart';
import '../widgets.dart';
import 'detail.dart';

/// The start page: what was watched lately, today's picks from the library,
/// today's recommendations to download, and what came in last.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  Home? _home;
  List<LibraryItem> _latest = [];
  Map<String, double> _progress = {};
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([App.api.home(), App.api.library()]);
      final home = results[0] as Home;
      final lib = (results[1] as List<LibraryItem>)..sort((a, b) => b.mtime.compareTo(a.mtime));
      final prefs = await SharedPreferences.getInstance();
      final progress = <String, double>{};
      for (final it in home.recent) {
        final v = prefs.getString('prog.${it.id}');
        final parts = v?.split('/');
        if (parts != null && parts.length == 2) {
          final pos = double.tryParse(parts[0]) ?? 0, dur = double.tryParse(parts[1]) ?? 0;
          if (dur > 0) progress[it.id] = (pos / dur).clamp(0, 1);
        }
      }
      if (!mounted) return;
      setState(() {
        _home = home;
        _latest = lib.take(24).toList();
        _progress = progress;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(LibraryItem it) => openDetail(context, it).then((_) => reload());

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 6 ? '夜深了' : h < 12 ? '早上好' : h < 18 ? '下午好' : '晚上好';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final home = _home;
    if (home == null) {
      return _error != null ? ErrorBox(_error!, onRetry: reload) : const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 36),
        children: [
          PageHeader(
            title: _greeting(),
            subtitle: '${home.date} · 每日推荐每天更新',
            actions: [
              IconButton.outlined(
                tooltip: '刷新',
                onPressed: _loading ? null : reload,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                style: IconButton.styleFrom(side: BorderSide(color: p.line)),
              ),
            ],
          ),
          if (home.recent.isNotEmpty)
            _Row(
              title: '最近观看',
              subtitle: '包括网页和 Emby 里看过的',
              height: 222,
              children: [for (final it in home.recent) _WideCard(item: it, progress: _progress[it.id], onTap: () => _open(it))],
            ),
          if (home.picks.isNotEmpty)
            _Row(
              title: '今日片库精选',
              subtitle: '片库里还没看过、合你口味的',
              height: 318,
              children: [for (final it in home.picks) SizedBox(width: 170, child: _poster(it))],
            ),
          if (home.recs.isNotEmpty)
            _Row(
              title: '每日新片推荐',
              subtitle: '片库里没有的，点开去搜索下载',
              height: 222,
              children: [
                for (final r in home.recs)
                  _WideCard(
                    image: App.api.image(r.cover),
                    title: r.code,
                    subtitle: r.reasons.isEmpty ? r.title : r.reasons.first,
                    badges: [
                      if (r.subMagnet) const Badge2('中字磁链'),
                      if (r.rating > 0) Badge2('★ ${r.rating.toStringAsFixed(1)}', color: badgeDark),
                    ],
                    onTap: () => Shell.search(context, r.code),
                  ),
              ],
            ),
          if (_latest.isNotEmpty)
            _Row(
              title: '最近入库',
              height: 318,
              children: [for (final it in _latest) SizedBox(width: 170, child: _poster(it))],
            ),
        ],
      ),
    );
  }

  Widget _poster(LibraryItem it) => PosterTile(
    image: it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : '',
    code: it.folder,
    subtitle: it.shortTitle,
    badges: [
      if (it.chineseSub) const Badge2('中字'),
      if (it.cloud) const Badge2('115', color: badgeBlue),
    ],
    onTap: () => _open(it),
  );
}

/// A titled row that scrolls sideways, with arrow buttons (a mouse wheel scrolls up/down).
class _Row extends StatefulWidget {
  const _Row({required this.title, required this.height, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final double height;
  final List<Widget> children;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _c = ScrollController();
  bool _start = true, _end = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update() {
    if (!_c.hasClients || !mounted) return;
    final s = _c.offset <= 4, e = _c.offset >= _c.position.maxScrollExtent - 4;
    if (s != _start || e != _end) {
      setState(() {
        _start = s;
        _end = e;
      });
    }
  }

  void _page(int dir) {
    if (!_c.hasClients) return;
    final target = (_c.offset + dir * _c.position.viewportDimension * 0.85).clamp(0.0, _c.position.maxScrollExtent);
    unawaited(_c.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 20, 12),
          child: Row(children: [
            Text(widget.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: p.text)),
            if (widget.subtitle != null) ...[
              const SizedBox(width: 10),
              Text(widget.subtitle!, style: TextStyle(color: p.muted, fontSize: 12.5)),
            ],
            const Spacer(),
            IconButton(onPressed: _start ? null : () => _page(-1), icon: const Icon(Icons.chevron_left_rounded)),
            IconButton(onPressed: _end ? null : () => _page(1), icon: const Icon(Icons.chevron_right_rounded)),
          ]),
        ),
        SizedBox(
          height: widget.height,
          child: ListView.separated(
            controller: _c,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
            itemCount: widget.children.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (_, i) => widget.children[i],
          ),
        ),
      ]),
    );
  }
}

/// A 16:9 card: a movie's fanart (or a recommendation's cover), title, and how far it was watched.
class _WideCard extends StatefulWidget {
  const _WideCard({this.item, this.progress, this.image, this.title, this.subtitle, this.badges = const [], required this.onTap});

  final LibraryItem? item;
  final double? progress;
  final String? image;
  final String? title;
  final String? subtitle;
  final List<Widget> badges;
  final VoidCallback onTap;

  @override
  State<_WideCard> createState() => _WideCardState();
}

class _WideCardState extends State<_WideCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final it = widget.item;
    final image = widget.image ??
        (it == null
            ? ''
            : it.fanart
            ? App.api.media(it.id, 'fanart.jpg', width: 480, version: it.posterVersion)
            : (it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : ''));
    final title = widget.title ?? it?.folder ?? '';
    final subtitle = widget.subtitle ??
        (it == null ? '' : [if (it.watchedAt > 0) '${fmtAgo(it.watchedAt)}看过', it.shortTitle].join(' · '));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 268,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _hover ? accent.withValues(alpha: 0.8) : p.line, width: _hover ? 1.5 : 1),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: _hover ? 0.3 : 0.1), blurRadius: _hover ? 16 : 6, offset: Offset(0, _hover ? 6 : 2))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(fit: StackFit.expand, children: [
                    NetImage(image, decodeWidth: 480),
                    if (_hover && it != null)
                      Container(
                        color: Colors.black26,
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                        ),
                      ),
                    Positioned(left: 7, top: 7, right: 7, child: Wrap(spacing: 4, children: widget.badges)),
                    if (widget.progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: widget.progress,
                          minHeight: 4,
                          color: accent,
                          backgroundColor: Colors.black45,
                        ),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: _hover ? accent : p.text)),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
