import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app.dart';

const accent = Color(0xFFE5484D);

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
      unawaited(file.writeAsBytes(r.bodyBytes).then((_) {}, onError: (_) {}));
      return _remember(url, r.bodyBytes);
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
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.decodeWidth, this.placeholder});

  final String url;
  final BoxFit fit;
  final int? decodeWidth;
  final Widget? placeholder;

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
    _failed = false;
    if (_bytes != null || widget.url.isEmpty) {
      _failed = widget.url.isEmpty;
      return;
    }
    final url = widget.url;
    ImageStore.instance.load(url, App.api.authHeaders).then((b) {
      if (!mounted || url != widget.url) return;
      setState(() {
        _bytes = b;
        _failed = b == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) {
      return widget.placeholder ??
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: _failed ? Icon(Icons.image_not_supported_outlined, color: Theme.of(context).hintColor) : null,
          );
    }
    return Image.memory(
      b,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: widget.decodeWidth,
      errorBuilder: (_, _, _) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
}

/// A small coloured label on a poster.
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color = accent});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
  );
}

/// One movie in a grid: poster, badges, code and title.
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
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1,
          duration: const Duration(milliseconds: 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetImage(widget.image, decodeWidth: 360),
                      if (_hover) Container(color: Colors.white.withValues(alpha: 0.06)),
                      Positioned(left: 6, top: 6, right: 6, child: Wrap(spacing: 4, runSpacing: 4, children: widget.badges)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(widget.code, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)));
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
        Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 32),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ],
    ),
  );
}
