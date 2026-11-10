import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';
import 'dest_picker.dart';

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  List<Job>? _jobs;
  String? _error;
  Timer? _timer;
  final _openLogs = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    _timer?.cancel();
    try {
      final jobs = await App.api.jobs();
      if (mounted) setState(() {
        _jobs = jobs;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    final active = _jobs?.any((j) => j.active) ?? false;
    if (mounted) _timer = Timer(Duration(milliseconds: active ? 2500 : 15000), _poll);
  }

  Future<void> _act(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    await _poll();
  }

  String _dest(String backend) => Backend(backend, true).title;

  Future<void> _addLink() async {
    final job = await showDialog<Job>(context: context, builder: (_) => const AddLinkDialog());
    if (job == null || !mounted) return;
    toast(context, '已创建任务 ${job.code} → ${_dest(job.backend)}');
    await _poll();
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _jobs;
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '下载任务',
          subtitle: jobs == null ? null : '${jobs.where((j) => j.active).length} 个进行中 · 共 ${jobs.length} 个',
          actions: [
            FilledButton.tonalIcon(onPressed: _addLink, icon: const Icon(Icons.add_link_rounded, size: 20), label: const Text('添加链接')),
            IconButton.outlined(tooltip: '刷新', onPressed: _poll, icon: const Icon(Icons.refresh_rounded, size: 20)),
          ],
        ),
        Expanded(
          child: jobs == null
              ? (_error != null ? ErrorBox(_error!, onRetry: _poll) : const Center(child: CircularProgressIndicator()))
              : jobs.isEmpty
              ? const EmptyHint('还没有任务：去「搜索与推荐」输入番号，或点「添加链接」粘贴磁力 / ed2k 链接', icon: Icons.download_outlined)
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), bottomGap(context)),
                  itemCount: jobs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final j = jobs[i];
                    final color = switch (j.status) {
                      'done' => Colors.green,
                      'failed' => Theme.of(context).colorScheme.error,
                      'canceled' => hint,
                      _ => accent,
                    };
                    final meta = [
                      jobStatusText[j.status] ?? j.status,
                      _dest(j.backend),
                      if (j.size > 0) fmtSize(j.size),
                      if (j.active && j.speed > 0) '${fmtSize(j.speed)}/s',
                      if (j.active && j.eta > 0) '剩余 ${fmtEta(j.eta)}',
                      fmtAgo(j.created),
                    ].where((s) => s.isNotEmpty).join(' · ');
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text.rich(TextSpan(children: [
                                        TextSpan(text: j.code, style: const TextStyle(fontWeight: FontWeight.w700)),
                                        TextSpan(text: '  ${j.title.length > 60 ? j.title.substring(0, 60) : j.title}', style: TextStyle(color: hint)),
                                      ])),
                                      const SizedBox(height: 4),
                                      Text(meta, style: TextStyle(color: color, fontSize: 12)),
                                      if (j.result.isNotEmpty) Text(j.result, style: TextStyle(color: hint, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: '操作',
                                  onSelected: (v) => switch (v) {
                                    'cancel' => _act(() => App.api.cancelJob(j.id)),
                                    'retry' => _act(() => App.api.retryJob(j.id)),
                                    'delete' => _act(() => App.api.deleteJob(j.id)),
                                    _ => setState(() => _openLogs.contains(j.id) ? _openLogs.remove(j.id) : _openLogs.add(j.id)),
                                  },
                                  itemBuilder: (_) => [
                                    if (j.active) const PopupMenuItem(value: 'cancel', child: Text('取消')),
                                    if (j.status == 'failed' || j.status == 'canceled') const PopupMenuItem(value: 'retry', child: Text('重试')),
                                    if (!j.active) const PopupMenuItem(value: 'delete', child: Text('删除')),
                                    PopupMenuItem(value: 'log', child: Text(_openLogs.contains(j.id) ? '收起日志' : '日志')),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: j.status == 'done' ? 1 : j.progress.clamp(0, 1),
                              color: color,
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            if (_openLogs.contains(j.id))
                              Container(
                                margin: const EdgeInsets.only(top: 10),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: Palette.of(context).raised, borderRadius: BorderRadius.circular(8)),
                                child: SelectableText(
                                  j.log.map((e) {
                                    final t = DateTime.fromMillisecondsSinceEpoch((e.$1 * 1000).round());
                                    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}  ${e.$2}';
                                  }).join('\n'),
                                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 添加链接: a magnet or ed2k link downloaded as it is; the 番号 (for the movie's
/// info and folder) is read from the link's file name unless typed.
class AddLinkDialog extends StatefulWidget {
  const AddLinkDialog({super.key, this.api});

  /// JavHub; a test's own.
  final JavHubApi? api;

  @override
  State<AddLinkDialog> createState() => _AddLinkDialogState();
}

class _AddLinkDialogState extends State<AddLinkDialog> {
  JavHubApi get _api => widget.api ?? App.api;
  final _link = TextEditingController();
  final _code = TextEditingController();
  Backends? _backends;
  String _dest = '';
  String _folder = '';
  bool _replace = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _link.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // a link just copied is what one came to add
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (mounted && _link.text.isEmpty && linkKind(clip).isNotEmpty) setState(() => _link.text = clip);
    } catch (_) {}
    try {
      final b = await _api.backends();
      if (!mounted) return;
      final ok = b.items.where((x) => x.ok).map((x) => x.name).toList();
      setState(() {
        _backends = b;
        _dest = ok.contains(b.preferred) ? b.preferred : (ok.isEmpty ? '' : ok.first);
        _fitDest();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String get _kind => linkKind(_link.text);

  /// qBittorrent is BitTorrent only: an ed2k link goes to a cloud drive's offline download.
  void _fitDest() {
    if (_kind != 'ed2k' || _dest != 'qbittorrent') return;
    _dest = _backends?.items.where((b) => b.ok && b.name != 'qbittorrent').firstOrNull?.name ?? '';
    _folder = '';
  }

  Future<void> _submit() async {
    final link = _link.text.trim();
    if (_kind.isEmpty) return setState(() => _error = '请粘贴磁力链接（magnet:?xt=urn:btih:…）或 ed2k 链接（ed2k://|file|…）');
    if (_dest.isEmpty) return setState(() => _error = _kind == 'ed2k' ? 'ed2k 链接需要 115 等网盘离线下载，请先在网页端「网盘」页登录' : '请先选择「下载到」哪里');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final job = await _api.createJob(_code.text.trim(), magnet: link, backend: _dest, replace: _replace, folder: _folder);
      if (mounted) Navigator.pop(context, job);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final link = _link.text.trim();
    final name = linkName(link);
    final note = link.isEmpty
        ? null
        : _kind.isEmpty
        ? '不是磁力或 ed2k 链接'
        : name.isNotEmpty
        ? '文件名：$name'
        : '这个链接没有文件名，请填上番号';
    return AlertDialog(
      title: const Text('添加磁力 / ed2k 链接'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _link,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '粘贴磁力链接（magnet:?xt=urn:btih:…）或 ed2k 链接（ed2k://|file|…）',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _fitDest();
                }),
              ),
              if (note != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(note, style: TextStyle(color: hint, fontSize: 12))),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                decoration: const InputDecoration(labelText: '番号', hintText: '留空则从链接的文件名识别', border: OutlineInputBorder(), isDense: true),
                onSubmitted: (_) => _busy ? null : _submit(),
              ),
              const SizedBox(height: 14),
              if (_backends == null && _error == null)
                const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
              else
                DestPicker(
                  backends: _backends,
                  dest: _dest,
                  folder: _folder,
                  disabled: _kind == 'ed2k' ? const {'qbittorrent'} : const {},
                  onChanged: (d, f) => setState(() {
                    _dest = d;
                    _folder = f;
                  }),
                ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(label: const Text('替换片库已有'), selected: _replace, onSelected: (v) => setState(() => _replace = v)),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '创建中…' : '开始下载')),
      ],
    );
  }
}
