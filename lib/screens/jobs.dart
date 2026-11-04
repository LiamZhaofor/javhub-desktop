import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../widgets.dart';

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
          actions: [IconButton.outlined(tooltip: '刷新', onPressed: _poll, icon: const Icon(Icons.refresh_rounded, size: 20))],
        ),
        Expanded(
          child: jobs == null
              ? (_error != null ? ErrorBox(_error!, onRetry: _poll) : const Center(child: CircularProgressIndicator()))
              : jobs.isEmpty
              ? const EmptyHint('还没有任务，去「搜索与推荐」输入番号开始', icon: Icons.download_outlined)
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), 32),
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
