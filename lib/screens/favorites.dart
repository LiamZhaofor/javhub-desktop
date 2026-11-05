import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'actor.dart';
import 'detail.dart';
import 'wishlist.dart';

/// 收藏: the movies marked ♥, the actresses followed, and the 想看 list (codes searched
/// for and downloaded when they turn up).
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => FavoritesPageState();
}

class FavoritesPageState extends State<FavoritesPage> {
  int _seg = 0; // 影片 | 演员 | 想看下载
  List<LibraryItem> _all = [];
  Map<String, Map<String, dynamic>> _follows = {};
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
      final r = await Future.wait([App.api.library(), App.api.follows()]);
      if (!mounted) return;
      setState(() {
        _all = r[0] as List<LibraryItem>;
        _follows = r[1] as Map<String, Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final favs = _all.where((it) => it.fav).toList()
      ..sort((a, b) => b.rating != a.rating ? b.rating.compareTo(a.rating) : b.mtime.compareTo(a.mtime));
    // one copy per code (a movie both on the NAS and on 115 is one favourite)
    final seen = <String>{};
    favs.retainWhere((it) => seen.add(it.code.toUpperCase()));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: '收藏',
        subtitle: '收藏的影片、关注的演员和想看清单',
        trailing: _loading
            ? const Padding(padding: EdgeInsets.only(left: 12, top: 4), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
            : null,
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, icon: const Icon(Icons.favorite_rounded, size: 18), label: Text('影片 ${favs.length}')),
              ButtonSegment(value: 1, icon: const Icon(Icons.person_rounded, size: 18), label: Text('演员 ${_follows.length}')),
              const ButtonSegment(value: 2, icon: Icon(Icons.download_for_offline_outlined, size: 18), label: Text('想看下载')),
            ],
            selected: {_seg},
            onSelectionChanged: (s) => setState(() => _seg = s.first),
          ),
        ),
      ),
      Expanded(
        child: switch (_seg) {
          2 => const WishlistPage(embedded: true),
          _ when _error != null && _all.isEmpty => ErrorBox(_error!, onRetry: reload),
          1 => _actors(),
          _ => _movies(favs),
        },
      ),
    ]);
  }

  Widget _movies(List<LibraryItem> favs) {
    if (favs.isEmpty) {
      return _loading && _all.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : const EmptyHint('还没有收藏的影片：在影片页点 ♡ 收藏', icon: Icons.favorite_border_rounded);
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), bottomGap(context)),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: isCompact(context) ? 140 : 186,
        mainAxisSpacing: isCompact(context) ? 14 : 22,
        crossAxisSpacing: isCompact(context) ? 10 : 18,
        childAspectRatio: 0.565,
      ),
      itemCount: favs.length,
      itemBuilder: (context, i) {
        final it = favs[i];
        return PosterTile(
          image: it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : '',
          code: it.folder,
          subtitle: it.shortTitle,
          badges: [if (it.chineseSub) const Badge2('中字'), if (it.cloud) const Badge2('115', color: badgeBlue)],
          corner: markBadges(it),
          onTap: () => openDetail(context, it).then((_) => reload()),
        );
      },
    );
  }

  Widget _actors() {
    final p = Palette.of(context);
    if (_follows.isEmpty) {
      return const EmptyHint('还没有关注的演员：点影片页的演员名，在演员页点“关注”', icon: Icons.person_add_alt_rounded);
    }
    final names = _follows.keys.toList()..sort((a, b) => _since(b).compareTo(_since(a)));
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), bottomGap(context)),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: isCompact(context) ? 140 : 170,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        childAspectRatio: 0.78,
      ),
      itemCount: names.length,
      itemBuilder: (context, i) {
        final name = names[i];
        final mine = _all.where((it) => it.actors.contains(name)).toList()..sort((a, b) => b.date.compareTo(a.date));
        final face = mine.where((it) => it.poster && it.actors.length == 1).firstOrNull ?? mine.where((it) => it.poster).firstOrNull;
        final jname = '${_follows[name]?['jname'] ?? ''}';
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => openActor(context, name).then((_) => reload()),
          child: Column(children: [
            const SizedBox(height: 6),
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipOval(
                  child: face == null
                      ? ColoredBox(color: p.raised, child: Icon(Icons.person_rounded, size: 48, color: p.muted))
                      // the face is usually in the upper part of a poster
                      : NetImage(App.api.media(face.id, 'poster.jpg', width: 360, version: face.posterVersion), alignment: const Alignment(0, -0.6)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: p.text)),
            Text([if (jname.isNotEmpty && jname != name) jname, '片库 ${mine.length} 部'].join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        );
      },
    );
  }

  double _since(String name) {
    final v = _follows[name]?['since'];
    return v is num ? v.toDouble() : 0;
  }
}
