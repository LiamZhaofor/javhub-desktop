import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';

class WishlistPage extends StatefulWidget {
  const WishlistPage({super.key, this.embedded = false});

  /// Inside 收藏 (which has its own title).
  final bool embedded;

  @override
  State<WishlistPage> createState() => _WishlistPageState();
}

class _WishlistPageState extends State<WishlistPage> {
  List<Wish>? _items;
  String? _error;
  final _code = TextEditingController();
  bool _needSub = true;
  final _checking = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await App.api.wishlist();
      if (mounted) setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _add() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    try {
      await App.api.addWish(code, needSub: _needSub);
      _code.clear();
      await _load();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Padding(
            padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), 10),
            child: Text('定期自动搜索这些番号，出现资源后自动下载（可选只等中字版）', style: TextStyle(color: Palette.of(context).muted, fontSize: 12.5)),
          )
        else
          const PageHeader(title: '想看', subtitle: '定期自动搜索，出现资源后自动下载（可选只等中字版）'),
        Padding(
          padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), 12),
          child: Row(children: [
            SizedBox(
              width: isCompact(context) ? 150 : 260,
              child: TextField(controller: _code, decoration: const InputDecoration(hintText: '番号'), onSubmitted: (_) => _add()),
            ),
            const SizedBox(width: 10),
            FilterChip(label: const Text('只要中字'), selected: _needSub, onSelected: (v) => setState(() => _needSub = v)),
            const SizedBox(width: 10),
            FilledButton(onPressed: _add, child: const Text('加入')),
          ]),
        ),
        Expanded(
          child: items == null
              ? (_error != null ? ErrorBox(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
              : items.isEmpty
              ? const EmptyHint('清单为空，搜索结果页可一键加入', icon: Icons.favorite_border_rounded)
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), bottomGap(context)),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final w = items[i];
                    final status = const {'waiting': '等待中', 'queued': '下载中', 'done': '已完成'}[w.status] ?? w.status;
                    return ListTile(
                      title: Row(children: [
                        Text(w.code, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        if (w.needSub) const Badge2('只要中字'),
                        const SizedBox(width: 6),
                        Badge2(status, color: w.status == 'done' ? const Color(0xFF16A34A) : w.status == 'queued' ? const Color(0xFFD97706) : const Color(0xFF6B7280)),
                      ]),
                      subtitle: Text('${w.lastResult.isEmpty ? '尚未检查' : w.lastResult}${w.lastCheck > 0 ? ' · ${fmtAgo(w.lastCheck)}' : ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(
                          onPressed: _checking.contains(w.code)
                              ? null
                              : () async {
                                  setState(() => _checking.add(w.code));
                                  try {
                                    await App.api.checkWish(w.code);
                                  } catch (e) {
                                    if (context.mounted) toast(context, '$e');
                                  }
                                  _checking.remove(w.code);
                                  await _load();
                                },
                          child: Text(_checking.contains(w.code) ? '检查中…' : '立即检查'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await App.api.removeWish(w.code);
                            await _load();
                          },
                          child: const Text('移除'),
                        ),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
