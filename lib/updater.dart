import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'models.dart';
import 'theme.dart';

/// A build of the app that JavHub has (CI uploads every release there).
class AppUpdate {
  AppUpdate(this.version, this.build, this.url, this.size, this.sha256, this.notes);

  factory AppUpdate.fromJson(Map<String, dynamic> j) => AppUpdate(
    '${j['version'] ?? ''}',
    j['build'] is num ? (j['build'] as num).toInt() : int.tryParse('${j['build']}') ?? 0,
    '${j['url'] ?? ''}',
    j['size'] is num ? (j['size'] as num).toInt() : 0,
    '${j['sha256'] ?? ''}',
    '${j['notes'] ?? ''}',
  );

  final String version;
  final int build;
  final String url;
  final int size;
  final String sha256;
  final String notes;
}

class Updater {
  static String get platform => Platform.isAndroid ? 'android' : 'windows';

  static Future<(String, int)> current() async {
    final p = await PackageInfo.fromPlatform();
    return (p.version, int.tryParse(p.buildNumber) ?? 0);
  }

  /// The newer build for this platform, or null.
  static Future<AppUpdate?> check() async {
    final m = await App.api.get('/api/updates');
    final e = m[platform];
    if (e is! Map) return null;
    final u = AppUpdate.fromJson(e.cast<String, dynamic>());
    final (_, build) = await current();
    return u.build > build && u.url.isNotEmpty ? u : null;
  }

  /// Downloads it (behind the login), checks it is the file JavHub announced.
  static Future<File> download(AppUpdate u, void Function(double) progress) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}updates');
    await dir.create(recursive: true);
    await for (final f in dir.list()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    final file = File('${dir.path}${Platform.pathSeparator}JavHub-${u.version}+${u.build}${Platform.isAndroid ? '.apk' : '.exe'}');
    final client = http.Client();
    try {
      final req = http.Request('GET', App.api.uri(u.url))..headers.addAll(App.api.authHeaders);
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('下载失败 (HTTP ${res.statusCode})');
      final total = res.contentLength ?? u.size;
      final sink = file.openWrite();
      final hashes = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(hashes);
      var got = 0;
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          if (total > 0) progress(got / total);
        }
      } finally {
        await sink.close();
        hasher.close();
      }
      if (u.sha256.isNotEmpty && hashes.events.single.toString() != u.sha256) {
        await file.delete();
        throw Exception('安装包校验失败，请重试');
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// Windows: the installer runs on its own (no questions), closes this app and
  /// starts the new one. Android: the system's install screen.
  static Future<void> install(File f) async {
    if (Platform.isWindows) {
      await Process.start(f.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/CLOSEAPPLICATIONS'],
          mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
    if (Platform.isAndroid) {
      await const MethodChannel('javhub/update').invokeMethod<bool>('installApk', {'path': f.path});
    }
  }
}

/// Asks (once per start) whether to install a newer build; `quiet` = no "up to date" message.
Future<void> checkForUpdate(BuildContext context, {bool quiet = true}) async {
  AppUpdate? u;
  try {
    u = await Updater.check();
  } catch (e) {
    if (!quiet && context.mounted) _snack(context, '检查更新失败: $e');
    return;
  }
  if (!context.mounted) return;
  if (u == null) {
    if (!quiet) {
      final (v, b) = await Updater.current();
      if (context.mounted) _snack(context, '已是最新版本 $v ($b)');
    }
    return;
  }
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => UpdateDialog(update: u!));
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.update});

  final AppUpdate update;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  double? _progress;
  String? _error;
  String _current = '';

  @override
  void initState() {
    super.initState();
    unawaited(Updater.current().then((c) {
      if (mounted) setState(() => _current = '${c.$1} (${c.$2})');
    }));
  }

  Future<void> _go() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final f = await Updater.download(widget.update, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _progress = 1);
      await Updater.install(f);
      if (mounted && Platform.isAndroid) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = '$e'.replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final u = widget.update;
    final busy = _progress != null;
    return AlertDialog(
      icon: const Icon(Icons.system_update_alt_rounded, color: accent, size: 32),
      title: Text('发现新版本 ${u.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('当前 $_current · 新版本 ${u.version} (${u.build}) · ${fmtSize(u.size)}', style: TextStyle(color: p.muted, fontSize: 12.5)),
          if (u.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(child: Text(u.notes, style: const TextStyle(height: 1.5))),
            ),
          ],
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
            const SizedBox(height: 6),
            Text(_progress! >= 1 ? (Platform.isAndroid ? '下载完成，正在打开安装界面…' : '下载完成，正在安装，JavHub 会自动重新打开…')
                : '正在下载 ${((_progress ?? 0) * 100).toStringAsFixed(0)}%', style: TextStyle(color: p.muted, fontSize: 12.5)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: accent)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: busy && _error == null ? null : () => Navigator.of(context).pop(), child: const Text('稍后')),
        FilledButton.icon(
          onPressed: busy && _error == null ? null : _go,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(_error == null ? '立即更新' : '重试'),
        ),
      ],
    );
  }
}

/// Collects the one digest a chunked hash produces.
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
