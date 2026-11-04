import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'detail.dart';

const _categories = ['有码', '无码', '素人', 'FC2'];
const _sorts = {'mtime': '最近入库', 'date': '发行日期', 'code': '番号', 'actor': '演员'};

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  List<LibraryItem> _all = [];
  bool _loading = true;
  String? _error;
  final _q = TextEditingController();
  Timer? _debounce;
  String _cat = '';
  String _where = ''; // '' | nas | cloud
  String _sub = ''; // '' | 1 | 0
  String _sort = 'mtime';

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
    unawaited(load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sort = p.getString('lib.sort') ?? 'mtime';
      _where = p.getString('lib.where') ?? '';
      _sub = p.getString('lib.sub') ?? '';
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lib.sort', _sort);
    await p.setString('lib.where', _where);
    await p.setString('lib.sub', _sub);
  }

  void setQuery(String q) {
    _q.text = q;
    setState(() => _cat = '');
  }

  Future<void> load({bool rescan = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await App.api.library(
        rescan: rescan,
        cached: (c) {
          if (mounted && _all.isEmpty) setState(() => _all = c);
        },
      );
      if (mounted) setState(() => _all = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<LibraryItem> _base() {
    final q = _q.text.trim();
    return _all
        .where((it) =>
            (_where.isEmpty || (_where == 'cloud') == it.cloud) &&
            (_sub.isEmpty || (_sub == '1') == it.chineseSub) &&
            it.matches(q))
        .toList();
  }

  List<LibraryItem> _view(List<LibraryItem> base) {
    final v = _cat.isEmpty ? base : base.where((it) => it.category == _cat).toList();
    int cmp(LibraryItem a, LibraryItem b) => switch (_sort) {
      'date' => b.date.compareTo(a.date),
      'code' => a.code.compareTo(b.code),
      'actor' => (a.actors.isEmpty ? '￿' : a.actors.first).compareTo(b.actors.isEmpty ? '￿' : b.actors.first),
      _ => b.mtime.compareTo(a.mtime),
    };
    v.sort(cmp);
    return v;
  }

  void _open(LibraryItem it) => openDetail(context, it);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final base = _base();
    final view = _view(base);
    final filtered = _q.text.isNotEmpty || _where.isNotEmpty || _sub.isNotEmpty || _cat.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '片库',
          subtitle: filtered ? '${view.length} / ${_all.length} 部' : '${_all.length} 部',
          trailing: _loading
              ? const Padding(padding: EdgeInsets.only(left: 12, top: 4), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
              : null,
          actions: [
            SizedBox(
              width: 300,
              child: TextField(
                controller: _q,
                decoration: InputDecoration(
                  hintText: '搜索番号、演员、标题、标签',
                  prefixIcon: Icon(Icons.search_rounded, size: 19, color: p.muted),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.close_rounded, size: 16), onPressed: () => setState(_q.clear)),
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 200), () => setState(() {}));
                },
              ),
            ),
            IconButton.outlined(
              tooltip: '重新扫描片库',
              onPressed: _loading ? null : () => load(rescan: true),
              icon: const Icon(Icons.refresh_rounded, size: 20),
              style: IconButton.styleFrom(side: BorderSide(color: p.line), fixedSize: const Size(42, 42)),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pagePad(context)),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in ['', ..._categories])
                ChoiceChip(
                  showCheckmark: false,
                  label: Text.rich(TextSpan(children: [
                    TextSpan(text: c.isEmpty ? '全部' : c, style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                      text: '  ${c.isEmpty ? base.length : base.where((it) => it.category == c).length}',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ])),
                  selected: _cat == c,
                  onSelected: (_) => setState(() => _cat = c),
                ),
              Container(width: 1, height: 22, color: p.line, margin: const EdgeInsets.symmetric(horizontal: 6)),
              SelectBox<String>(
                value: _where,
                icon: Icons.place_outlined,
                options: const {'': '全部位置', 'nas': 'NAS 本地', 'cloud': '115 网盘'},
                onChanged: (v) => _set(() => _where = v),
              ),
              SelectBox<String>(
                value: _sub,
                icon: Icons.subtitles_outlined,
                options: const {'': '字幕不限', '1': '中文字幕', '0': '无字幕'},
                onChanged: (v) => _set(() => _sub = v),
              ),
              SelectBox<String>(value: _sort, icon: Icons.sort_rounded, options: _sorts, onChanged: (v) => _set(() => _sort = v)),
              if (filtered)
                TextButton.icon(
                  onPressed: () => _set(() {
                    _q.clear();
                    _where = _sub = _cat = '';
                  }),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                  label: const Text('清除筛选'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _error != null && _all.isEmpty
              ? ErrorBox(_error!, onRetry: load)
              : view.isEmpty
              ? (_loading ? const Center(child: CircularProgressIndicator()) : const EmptyHint('没有符合条件的影片', icon: Icons.movie_filter_outlined))
              : Scrollbar(
                  child: GridView.builder(
                    padding: EdgeInsets.fromLTRB(pagePad(context), 8, pagePad(context), bottomGap(context)),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: isCompact(context) ? 140 : 186,
                      mainAxisSpacing: isCompact(context) ? 14 : 22,
                      crossAxisSpacing: isCompact(context) ? 10 : 18,
                      childAspectRatio: 0.565,
                    ),
                    itemCount: view.length,
                    itemBuilder: (context, i) {
                      final it = view[i];
                      return PosterTile(
                        image: it.poster ? App.api.media(it.id, 'poster.jpg', width: 360, version: it.posterVersion) : '',
                        code: it.folder,
                        subtitle: it.shortTitle,
                        badges: [
                          if (it.chineseSub) const Badge2('中字'),
                          if (it.cloud) const Badge2('115', color: badgeBlue),
                          if (it.category.isNotEmpty && it.category != '有码') Badge2(it.category, color: badgeDark),
                          if (it.leak) const Badge2('流出', color: badgeDark),
                        ],
                        onTap: () => _open(it),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  void _set(VoidCallback f) {
    setState(f);
    unawaited(_save());
  }
}
