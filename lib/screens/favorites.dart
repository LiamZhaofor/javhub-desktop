import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'actor.dart';
import 'detail.dart';
import 'wishlist.dart';

/// 收藏's segments.
const _segMovies = 0, _segActors = 1, _segWish = 2, _segNew = 3;

/// 收藏: the movies marked ♥, the actresses followed, and the 想看 list (codes searched
/// for and downloaded when they turn up).
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => FavoritesPageState();
}

class FavoritesPageState extends State<FavoritesPage> {
  int _seg = _segMovies;
  List<LibraryItem> _all = [];
  Map<String, Map<String, dynamic>> _follows = {};
  Releases? _releases;
  Timer? _checking;
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
      final r = await Future.wait([App.api.library(), App.api.follows(), App.api.releases()]);
      if (!mounted) return;
      setState(() {
        _all = r[0] as List<LibraryItem>;
        _follows = r[1] as Map<String, Map<String, dynamic>>;
        _releases = r[2] as Releases;
        _error = null;
      });
      Shell.setNewReleases(_releases!.unread);
      if (_seg == _segNew) unawaited(_markRead());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _checking?.cancel();
    super.dispose();
  }

  /// The 新 marks stay on screen until the next visit; the badge goes now.
  Future<void> _markRead() async {
    if ((_releases?.unread ?? 0) == 0) return;
    try {
      await App.api.releasesRead();
      Shell.setNewReleases(0);
    } catch (_) {}
  }

  Future<void> _checkNow() async {
    try {
      final r = await App.api.releasesCheck();
      if (mounted) setState(() => _releases = r);
    } catch (e) {
      if (mounted) toast(context, '$e');
      return;
    }
    // a look at every followed actress takes a while (15 s apart): follow it
    _checking?.cancel();
    _checking = Timer.periodic(const Duration(seconds: 5), (t) async {
      try {
        final r = await App.api.releases();
        if (!mounted) return t.cancel();
        setState(() => _releases = r);
        if (!r.checking) {
          t.cancel();
          Shell.setNewReleases(_seg == _segNew ? 0 : r.unread);
          if (_seg == _segNew) unawaited(_markRead());
        }
      } catch (_) {}
    });
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
              ButtonSegment(value: _segMovies, icon: const Icon(Icons.favorite_rounded, size: 18), label: Text('影片 ${favs.length}')),
              ButtonSegment(value: _segActors, icon: const Icon(Icons.person_rounded, size: 18), label: Text('演员 ${_follows.length}')),
              ButtonSegment(
                value: _segNew,
                icon: Badge(
                  isLabelVisible: (_releases?.unread ?? 0) > 0,
                  label: Text('${_releases?.unread ?? 0}'),
                  child: const Icon(Icons.new_releases_outlined, size: 18),
                ),
                label: const Text('新片'),
              ),
              const ButtonSegment(value: _segWish, icon: Icon(Icons.download_for_offline_outlined, size: 18), label: Text('想看下载')),
            ],
            selected: {_seg},
            onSelectionChanged: (s) {
              setState(() => _seg = s.first);
              if (_seg == _segNew) unawaited(_markRead());
            },
          ),
        ),
      ),
      Expanded(
        child: switch (_seg) {
          _segWish => const WishlistPage(embedded: true),
          _ when _error != null && _all.isEmpty => ErrorBox(_error!, onRetry: reload),
          _segActors => _actors(),
          _segNew => _newReleases(),
          _ => _movies(favs),
        },
      ),
    ]);
  }

  Widget _movies(List<LibraryItem> favs) {
    if (favs.isEmpty) {
      return _loading && _all.isEmpty
          ? const SkeletonGrid()
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
        return Appear(
          key: ValueKey('f-${it.id}'),
          index: i,
          child: PosterTile(
            image: it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : '',
            code: it.folder,
            subtitle: it.shortTitle,
            badges: [if (it.chineseSub) const Badge2('中字'), if (it.cloud) const Badge2('115', color: badgeBlue)],
            corner: markBadges(it),
            onTap: () => openDetail(context, it).then((_) => reload()),
          ),
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

  Widget _newReleases() {
    final p = Palette.of(context);
    final r = _releases;
    if (r == null) return const Center(child: CircularProgressIndicator());
    final info = [
      if (r.follows == 0) '还没有关注的演员：在演员页点“关注”后，她的新片会出现在这里' else '每 12 小时检查一次关注的 ${r.follows} 位演员',
      if (r.lastCheck > 0) '上次检查 ${fmtAgo(r.lastCheck)}',
      if (r.checking) '检查中…',
    ].join(' · ');
    final head = Padding(
      padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), 10),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(info, style: TextStyle(color: p.muted, fontSize: 12.5)),
        if (r.error.isNotEmpty) Text(r.error, style: const TextStyle(color: accent, fontSize: 12.5)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Switch(
            value: r.autoWish,
            onChanged: (v) async {
              try {
                await App.api.releasesSettings(autoWish: v);
                await reload();
                if (mounted) toast(context, v ? '新片会自动加入想看清单（等有中字资源后下载）' : '不再自动加入想看');
              } catch (e) {
                if (mounted) toast(context, '$e');
              }
            },
          ),
          Text('自动加入想看', style: TextStyle(color: p.text, fontSize: 13)),
        ]),
        OutlinedButton.icon(
          onPressed: r.checking || r.follows == 0 ? null : _checkNow,
          icon: r.checking
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('立即检查'),
        ),
      ]),
    );
    if (r.items.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        if (r.follows > 0) const Expanded(child: EmptyHint('暂时没有新片。出现后会显示在这里，「收藏」上会有数字提醒', icon: Icons.new_releases_outlined)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      Expanded(
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), bottomGap(context)),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: isCompact(context) ? 140 : 186,
            mainAxisSpacing: isCompact(context) ? 14 : 22,
            crossAxisSpacing: isCompact(context) ? 10 : 18,
            childAspectRatio: 0.565,
          ),
          itemCount: r.items.length,
          itemBuilder: (context, i) {
            final w = r.items[i];
            return PosterTile(
              image: w.cover.isEmpty ? '' : App.api.image(w.cover),
              cover: true,
              code: w.code,
              subtitle: [w.actor, if (w.date.isNotEmpty) w.date].join(' · '),
              badges: [
                if (!w.read) const Badge2('新'),
                if (w.inLibrary != null) const Badge2('片库已有', color: Color(0xFF16A34A)) else if (w.wished) const Badge2('想看', color: badgeBlue),
                if (w.magnet == 'sub') const Badge2('中字磁链', color: badgeDark),
              ],
              onTap: () => Shell.search(context, w.code),
            );
          },
        ),
      ),
    ]);
  }

  double _since(String name) {
    final v = _follows[name]?['since'];
    return v is num ? v.toDouble() : 0;
  }
}
