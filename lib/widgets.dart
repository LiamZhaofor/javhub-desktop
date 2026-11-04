import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'theme.dart';

export 'theme.dart' show accent, Palette, PageHeader;

/// Pictures from JavHub, kept on disk: the library's poster URLs carry the
/// artwork version (`v=`), so a cached file is good for as long as the URL is.
class ImageStore {
  ImageStore._();

  static final instance = ImageStore._();

  final _memory = LinkedHashMap<String, Uint8List>();
  int _memoryBytes = 0;
  final _loading = <String, Future<Uint8List?>>{};
  final _client = http.Client();
  Directory? _dir;
  int _running = 0;
  final _queue = Queue<Completer<void>>();

  static String _key(String url) {
    // FNV-1a, 64 bit: a file name per URL without pulling in a crypto package
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(url)) {
      h ^= b;
      h *= 0x100000001b3; // wraps at 64 bits
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  Future<Directory> _cacheDir() async {
    final d = _dir ??= Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}images');
    await d.create(recursive: true);
    return d;
  }

  Uint8List? peek(String url) => _memory[url];

  Future<Uint8List?> load(String url, Map<String, String> headers) {
    final hit = _memory[url];
    if (hit != null) return Future.value(hit);
    return _loading[url] ??= _load(url, headers).whenComplete(() => _loading.remove(url));
  }

  Future<Uint8List?> _load(String url, Map<String, String> headers) async {
    final file = File('${(await _cacheDir()).path}${Platform.pathSeparator}${_key(url)}');
    try {
      if (await file.exists()) return _remember(url, await file.readAsBytes());
    } catch (_) {}
    // a few at a time: dozens of parallel requests over a slow uplink all arrive late
    await _slot();
    try {
      final r = await _client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 40));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final bytes = Uint8List.fromList(r.bodyBytes);
      unawaited(file.writeAsBytes(bytes).then((_) {}, onError: (_) {}));
      return _remember(url, bytes);
    } catch (_) {
      return null;
    } finally {
      _done();
    }
  }

  Future<void> _slot() async {
    if (_running < 6) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
  }

  void _done() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _running--;
    }
  }

  Uint8List _remember(String url, Uint8List data) {
    _memory[url] = data;
    _memoryBytes += data.length;
    while (_memoryBytes > (80 << 20) && _memory.length > 1) {
      _memoryBytes -= _memory.remove(_memory.keys.first)!.length;
    }
    return data;
  }
}

class NetImage extends StatefulWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.decodeWidth});

  final String url;
  final BoxFit fit;
  final int? decodeWidth;

  @override
  State<NetImage> createState() => _NetImageState();
}

class _NetImageState extends State<NetImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(NetImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _fetch();
  }

  void _fetch() {
    _bytes = ImageStore.instance.peek(widget.url);
    _failed = widget.url.isEmpty;
    if (_bytes != null || _failed) return;
    final url = widget.url;
    ImageStore.instance.load(url, App.api.authHeaders).then((b) {
      if (!mounted || url != widget.url) return;
      setState(() {
        _bytes = b;
        _failed = b == null;
      });
    });
  }

  Widget _empty(BuildContext context, {bool broken = false}) {
    final p = Palette.of(context);
    return Container(
      color: p.raised,
      alignment: Alignment.center,
      child: broken ? Icon(Icons.movie_outlined, color: p.muted.withValues(alpha: 0.6), size: 28) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return _empty(context, broken: _failed);
    return Image.memory(
      b,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: widget.decodeWidth,
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
      errorBuilder: (context, _, _) => _empty(context, broken: true),
    );
  }
}

/// A small label on a poster.
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color = accent});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(5),
      boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4)],
    ),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, height: 1.3)),
  );
}

const badgeDark = Color(0xB3000000);
const badgeBlue = Color(0xFF2563EB);

/// One movie in a grid: poster with badges, then code and title.
class PosterTile extends StatefulWidget {
  const PosterTile({
    super.key,
    required this.image,
    required this.code,
    required this.subtitle,
    this.badges = const [],
    this.onTap,
  });

  final String image;
  final String code;
  final String subtitle;
  final List<Widget> badges;
  final VoidCallback? onTap;

  @override
  State<PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<PosterTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(0, _hover ? -4 : 0, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _hover ? accent.withValues(alpha: 0.8) : p.line, width: _hover ? 1.5 : 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: _hover ? 0.35 : 0.12),
                      blurRadius: _hover ? 18 : 6,
                      offset: Offset(0, _hover ? 8 : 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetImage(widget.image, decodeWidth: 360),
                      Positioned(left: 7, top: 7, right: 7, child: Wrap(spacing: 4, runSpacing: 4, children: widget.badges)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(widget.code, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: _hover ? accent : p.text)),
            const SizedBox(height: 2),
            Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_outlined, color: Palette.of(context).muted, size: 36),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 14),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ],
    ),
  );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: p.muted.withValues(alpha: 0.6)),
        const SizedBox(height: 10),
        Text(text, style: TextStyle(color: p.muted)),
      ]),
    );
  }
}

/// A rounded, bordered drop-down that fits next to chips.
class SelectBox<T> extends StatelessWidget {
  const SelectBox({super.key, required this.value, required this.options, required this.onChanged, this.icon});

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(color: p.surface, border: Border.all(color: p.line), borderRadius: BorderRadius.circular(8)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: options.containsKey(value) ? value : options.keys.first,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          dropdownColor: p.surface,
          icon: Icon(Icons.expand_more, size: 18, color: p.muted),
          style: TextStyle(color: p.text, fontSize: 13, fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily),
          items: [
            for (final e in options.entries)
              DropdownMenuItem(
                value: e.key,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 15, color: p.muted), const SizedBox(width: 6)],
                  Text(e.value),
                ]),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
