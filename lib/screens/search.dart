import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'dest_picker.dart';

const _subPolicies = {'': '字幕默认', 'prefer': '优先中字', 'require': '只要中字', 'ignore': '不看字幕'};

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.onJobCreated});

  final VoidCallback? onJobCreated;

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  final _q = TextEditingController();
  String _policy = '';
  bool _busy = false;
  String? _error;
  SearchResult? _result;
  Backends? _backends;
  String _dest = '';

  /// A 115 destination: which library folder ('' = the usual one).
  String _folder = '';
  bool _replace = false;

  Recs? _recs;
  int _recOffset = 0;
  Timer? _recTimer;
  static const _recPage = 18;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecs());
    unawaited(_loadBackends());
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadBackends() async {
    try {
      final b = await App.api.backends();
      final ok = b.items.where((x) => x.ok).map((x) => x.name).toList();
      if (!mounted) return;
      setState(() {
        _backends = b;
        // every new movie starts at JavHub's default (115); a choice is for that download
        _dest = ok.contains(b.preferred) ? b.preferred : (ok.isEmpty ? '' : ok.first);
        _folder = '';
      });
    } catch (_) {}
  }

  Future<void> _loadRecs({bool refresh = false}) async {
    _recTimer?.cancel();
    try {
      final r = await App.api.recs(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _recs = r;
        if (refresh) _recOffset = 0;
      });
      if (r.running) _recTimer = Timer(const Duration(seconds: 4), _loadRecs);
    } catch (e) {
      if (refresh && mounted) toast(context, '$e');
    }
  }

  Future<void> search(String code, {bool refresh = false}) async {
    code = code.trim();
    if (code.isEmpty) return;
    _q.text = code;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await App.api.search(code, subtitle: _policy, refresh: refresh);
      if (_backends == null) await _loadBackends();
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(String code, {String? magnet}) async {
    if (_dest.isEmpty) {
      toast(context, '请先选择「下载到」哪里');
      return;
    }
    try {
      final job = await App.api.createJob(code, magnet: magnet, backend: _dest, replace: _replace, subtitle: _policy, folder: _folder);
      widget.onJobCreated?.call();
      if (mounted) {
        final b = _backends?.items.where((b) => b.name == _dest).firstOrNull;
        final where = _folder.isNotEmpty ? _folder : (b?.dir ?? '');
        toast(context, '已创建任务 ${job.code} → ${b?.title ?? _dest}${where.isEmpty ? '' : '（$where）'}，进度见「任务」页');
      }
    } catch (e) {
      if (mounted) toast(context, '创建失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: '搜索与推荐', subtitle: '按番号查影片信息和磁力，一键下载到 NAS 或 115'),
        Padding(
          padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), 16),
          child: Row(
            children: [
              if (_result != null) ...[
                IconButton.filledTonal(tooltip: '返回推荐', onPressed: () => setState(() => _result = null), icon: const Icon(Icons.arrow_back_rounded)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: TextField(
                  controller: _q,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: '输入番号，如 SSIS-001',
                    prefixIcon: Icon(Icons.search_rounded, size: 20, color: Palette.of(context).muted),
                  ),
                  onSubmitted: (v) => search(v),
                ),
              ),
              const SizedBox(width: 10),
              if (!isCompact(context)) ...[
                SelectBox<String>(value: _policy, icon: Icons.subtitles_outlined, options: _subPolicies, onChanged: (v) => setState(() => _policy = v)),
                const SizedBox(width: 10),
              ],
              isCompact(context)
                  ? IconButton.filled(onPressed: _busy ? null : () => search(_q.text), icon: const Icon(Icons.search_rounded))
                  : FilledButton.icon(
                      onPressed: _busy ? null : () => search(_q.text),
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('搜索'),
                    ),
            ],
          ),
        ),
        Expanded(
          child: _busy
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text('正在查询 ${_q.text}：影片信息 + 磁力源…'),
                ]))
              : _error != null
              ? ErrorBox(_error!, onRetry: () => search(_q.text))
              : _result != null
              ? _resultView(_result!)
              : _recsView(),
        ),
      ],
    );
  }

  // ---------------- recommendations ----------------

  Widget _recsView() {
    final r = _recs;
    final hint = Theme.of(context).hintColor;
    if (r == null) return const Center(child: CircularProgressIndicator());
    final items = r.items;
    final page = items.skip(_recOffset).take(_recPage).toList();
    final b = r.basis;
    final actors = (b['actors'] is List) ? (b['actors'] as List).take(3).join('、') : '';
    final why = b['library'] != null
        ? '根据片库 ${b['library']} 部${b['watched'] != null && b['watched'] != 0 ? '、最近看过 ${b['watched']} 部' : ''}'
            '${(b['liked'] ?? 0) != 0 ? '、收藏/高分 ${b['liked']} 部' : ''}${(b['disliked'] ?? 0) != 0 ? '，避开屏蔽/低分 ${b['disliked']} 部' : ''}'
            '${actors.isEmpty ? '' : '；偏好：$actors'}'
        : '';
    return ListView(
      padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), bottomGap(context)),
      children: [
        Row(
          children: [
            Text('为你推荐', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                [why, r.running ? '正在分析口味…' : (r.ts > 0 ? '${fmtAgo(r.ts)}更新' : '')].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(color: hint, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (items.length > _recPage)
              TextButton(
                onPressed: () => setState(() => _recOffset = _recOffset + _recPage >= items.length ? 0 : _recOffset + _recPage),
                child: const Text('换一批'),
              ),
            TextButton(onPressed: r.running ? null : () => _loadRecs(refresh: true), child: const Text('重新计算')),
          ],
        ),
        if (r.error.isNotEmpty) Text(r.error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        if (page.isEmpty && !r.running)
          Padding(padding: const EdgeInsets.all(24), child: Text('还没有推荐（片库为空或 JavDB 无法访问）', style: TextStyle(color: hint)))
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: isCompact(context) ? 140 : 186,
              mainAxisSpacing: isCompact(context) ? 14 : 22,
              crossAxisSpacing: isCompact(context) ? 10 : 18,
              childAspectRatio: 0.565,
            ),
            itemCount: page.length,
            itemBuilder: (context, i) {
              final rec = page[i];
              return PosterTile(
                image: rec.cover.isEmpty ? '' : App.api.image(rec.cover),
                cover: true,
                code: rec.code,
                subtitle: rec.reasons.isEmpty ? rec.title : rec.reasons.first,
                badges: [
                  if (rec.subMagnet) const Badge2('中字磁链'),
                  if (rec.upcoming) const Badge2('未发售', color: badgeDark) else if (rec.wished) const Badge2('想看', color: badgeBlue),
                  if (rec.rating > 0) Badge2('★ ${rec.rating.toStringAsFixed(1)}', color: badgeDark),
                ],
                onTap: () => search(rec.code),
              );
            },
          ),
      ],
    );
  }

  // ---------------- a search result ----------------

  Widget _resultView(SearchResult d) {
    final m = d.movie;
    final hint = Theme.of(context).hintColor;
    final usable = d.usable;
    final okBackends = _backends?.items.where((b) => b.ok).toList() ?? [];
    return ListView(
      padding: EdgeInsets.fromLTRB(pagePad(context), 0, pagePad(context), bottomGap(context)),
      children: [
        if (d.found)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Flex(
                direction: isCompact(context) ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.cover.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: isCompact(context) ? double.infinity : 420,
                        child: AspectRatio(aspectRatio: 1.5, child: NetImage(App.api.image(m.cover))),
                      ),
                    ),
                  const SizedBox(width: 20, height: 14),
                  Flexible(
                    fit: isCompact(context) ? FlexFit.loose : FlexFit.tight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText('${d.code} ${m.title}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        _kv('发行', '${m.date.isEmpty ? '-' : m.date}${m.runtime > 0 ? ' · ${m.runtime} 分钟' : ''}'),
                        _kv('演员', m.actors.isEmpty ? '-' : m.actors.join('、')),
                        _kv('片商', '${m.studio.isEmpty ? '-' : m.studio}${m.label.isEmpty ? '' : ' / ${m.label}'}'),
                        if (m.series.isNotEmpty) _kv('系列', m.series),
                        if (m.director.isNotEmpty) _kv('导演', m.director),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 6, children: [for (final t in m.tags) Chip(label: Text(t), visualDensity: VisualDensity.compact)]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          _notice('没有找到 ${d.code} 的影片信息（仍可按磁力下载）。'),
        if (m.samples.isNotEmpty)
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: m.samples.length.clamp(0, 16),
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => InkWell(
                onTap: () => _showSample(m.samples, i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(aspectRatio: 1.4, child: NetImage(App.api.image(m.samples[i]), decodeWidth: 300)),
                ),
              ),
            ),
          ),
        if (d.inLibrary.isNotEmpty)
          _notice('📁 片库已有：${d.inLibrary.map((i) => i.folder + (i.chineseSub ? ' (中字)' : '')).join('，')} —— 下载会另存为新版本，勾选「替换」则覆盖。'),
        if (d.activeJob != null) _notice('⏳ 已有进行中的任务（${jobStatusText[d.activeJob!['status']] ?? d.activeJob!['status']}），见「任务」页。'),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DestPicker(
                  backends: _backends,
                  dest: _dest,
                  folder: _folder,
                  onChanged: (d, f) => setState(() {
                    _dest = d;
                    _folder = f;
                  }),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('磁力候选  ${usable.length}/${d.candidates.length} 可用', style: const TextStyle(fontWeight: FontWeight.w700)),
                    for (final s in d.sources)
                      Tooltip(
                        message: '${s['error'] ?? ''}',
                        child: Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('${s['source']} ${s['ok'] == true ? (s['count'] ?? '') : '✕'}'),
                          side: BorderSide(color: s['ok'] == true ? Colors.green.shade700 : Colors.red.shade700),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(label: const Text('替换片库已有'), selected: _replace, onSelected: (v) => setState(() => _replace = v)),
                    FilledButton.icon(
                      onPressed: usable.isEmpty ? null : () => _download(d.code),
                      icon: const Icon(Icons.download),
                      label: Text(_dest.isEmpty ? '自动选择最佳并下载' : '自动选最佳 → ${okBackends.where((b) => b.name == _dest).firstOrNull?.title ?? ''}'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await App.api.addWish(d.code, needSub: true);
                          if (mounted) toast(context, '已加入想看清单');
                        } catch (e) {
                          if (mounted) toast(context, '$e');
                        }
                      },
                      icon: const Icon(Icons.favorite_border),
                      label: const Text('加入想看（等中字）'),
                    ),
                    TextButton(onPressed: () => search(d.code, refresh: true), child: const Text('重新抓取')),
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text('屏蔽 ${d.code}？'),
                            content: const Text('它不会再出现在推荐、首页和演员页里。可以在 设置 → 已屏蔽的影片 里取消屏蔽。'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('屏蔽')),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        try {
                          await App.api.block(d.code, true, title: m.title, cover: m.cover);
                          if (mounted) toast(context, '已屏蔽 ${d.code}');
                        } catch (e) {
                          if (mounted) toast(context, '$e');
                        }
                      },
                      icon: const Icon(Icons.block_rounded, size: 18),
                      label: const Text('屏蔽'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (d.candidates.isEmpty)
                  Padding(padding: const EdgeInsets.all(12), child: Text('没有找到磁力', style: TextStyle(color: hint)))
                else
                  for (var i = 0; i < d.candidates.length; i++) _candidate(d, i),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _candidate(SearchResult d, int i) {
    final c = d.candidates[i];
    final rejected = c.rejected.isNotEmpty;
    final hint = Theme.of(context).hintColor;
    if (isCompact(context)) {
      return Opacity(
        opacity: rejected ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${i + 1}. ${c.title}', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final r in c.reasons)
                Badge2(r, color: r == '中文字幕' ? accent : (r == '4K' || r == '1080p') ? const Color(0xFF16A34A) : const Color(0xFF6B7280)),
              if (rejected) Badge2(c.rejected, color: Colors.red.shade900),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Text(c.size, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              Text('评分 ${c.score}', style: TextStyle(color: hint, fontSize: 12)),
              const Spacer(),
              IconButton(
                tooltip: '复制磁力',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: c.magnet));
                  if (mounted) toast(context, '磁力已复制');
                },
              ),
              FilledButton.tonal(onPressed: () => _download(d.code, magnet: c.magnet), child: const Text('下载')),
            ]),
          ]),
        ),
      );
    }
    return Opacity(
      opacity: rejected ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)))),
        child: Row(
          children: [
            SizedBox(width: 28, child: Text('${i + 1}', style: TextStyle(color: hint))),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final r in c.reasons)
                      Badge2(r, color: r == '中文字幕' ? accent : (r == '4K' || r == '1080p') ? const Color(0xFF16A34A) : const Color(0xFF6B7280)),
                    if (rejected) Badge2(c.rejected, color: Colors.red.shade900),
                  ]),
                ],
              ),
            ),
            SizedBox(width: 90, child: Text(c.size, textAlign: TextAlign.right)),
            SizedBox(width: 140, child: Text(c.sources.join(', '), textAlign: TextAlign.center, style: TextStyle(color: hint, fontSize: 12))),
            SizedBox(width: 48, child: Text('${c.score}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: () => _download(d.code, magnet: c.magnet), child: const Text('下载')),
            IconButton(
              tooltip: '复制磁力',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: c.magnet));
                if (mounted) toast(context, '磁力已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSample(List<String> samples, int start) => showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: PageView(
        controller: PageController(initialPage: start),
        children: [for (final s in samples) InteractiveViewer(child: NetImage(App.api.image(s), fit: BoxFit.contain))],
      ),
    ),
  );

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 44, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
      Expanded(child: SelectableText(v)),
    ]),
  );

  Widget _notice(String text) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4),
    child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
  );
}
