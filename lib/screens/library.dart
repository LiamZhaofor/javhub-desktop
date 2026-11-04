import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../models.dart';
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

  void _open(LibraryItem it) => Navigator.of(context).push(MaterialPageRoute(
    builder: (route) => DetailPage(
      item: it,
      onFilter: (q) {
        Navigator.of(route).pop();
        setQuery(q);
      },
      onSearch: (code) {
        Navigator.of(route).pop();
        Shell.search(context, code);
      },
    ),
  ));

  @override
  Widget build(BuildContext context) {
    final base = _base();
    final view = _view(base);
    final filtered = _q.text.isNotEmpty || _where.isNotEmpty || _sub.isNotEmpty || _cat.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Text('片库', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text(filtered ? '${view.length} / ${_all.length} 部' : '${_all.length} 部',
                  style: TextStyle(color: Theme.of(context).hintColor)),
              if (_loading) const Padding(padding: EdgeInsets.only(left: 10), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _q,
                  decoration: InputDecoration(
                    hintText: '番号 / 演员 / 标题 / 标签',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _q.text.isEmpty
                        ? null
                        : IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(_q.clear)),
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 200), () => setState(() {}));
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '重新扫描片库',
                onPressed: _loading ? null : () => load(rescan: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in ['', ..._categories])
                ChoiceChip(
                  label: Text('${c.isEmpty ? '全部' : c}  ${c.isEmpty ? base.length : base.where((it) => it.category == c).length}'),
                  selected: _cat == c,
                  onSelected: (_) => setState(() => _cat = c),
                ),
              const SizedBox(width: 12),
              _drop('位置', _where, const {'': '全部位置', 'nas': 'NAS 本地', 'cloud': '网盘'}, (v) => _where = v),
              _drop('字幕', _sub, const {'': '字幕不限', '1': '中文字幕', '0': '无字幕'}, (v) => _sub = v),
              _drop('排序', _sort, _sorts, (v) => _sort = v),
              if (filtered)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _q.clear();
                    _where = _sub = _cat = '';
                    unawaited(_save());
                  }),
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text('清除筛选'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _error != null && _all.isEmpty
              ? ErrorBox(_error!, onRetry: load)
              : view.isEmpty
              ? Center(child: Text(_loading ? '加载中…' : '没有符合条件的影片', style: TextStyle(color: Theme.of(context).hintColor)))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisSpacing: 18,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.58,
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
                        if (it.cloud) const Badge2('115', color: Color(0xFF2563EB)),
                        if (it.category.isNotEmpty && it.category != '有码') Badge2(it.category, color: Colors.black54),
                        if (it.leak) const Badge2('流出', color: Colors.black54),
                      ],
                      onTap: () => _open(it),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _drop(String label, String value, Map<String, String> options, void Function(String) set) => DropdownButtonHideUnderline(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<String>(
        value: options.containsKey(value) ? value : options.keys.first,
        isDense: true,
        items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() {
          set(v ?? '');
          unawaited(_save());
        }),
      ),
    ),
  );
}
