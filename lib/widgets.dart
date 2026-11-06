import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'models.dart';
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
    // (a block body: `=> _loading.remove(url)` would hand whenComplete this very
    // future to wait for, and it would never complete)
    return _loading[url] ??= _load(url, headers).whenComplete(() {
      _loading.remove(url);
    });
  }

  Future<Uint8List?> _load(String url, Map<String, String> headers) async {
    final file = File('${(await _cacheDir()).path}${Platform.pathSeparator}${_key(App.api.canonical(url))}');
    try {
      if (await file.exists()) return _remember(url, await file.readAsBytes());
    } catch (_) {}
    // a few at a time: dozens of parallel requests over a slow uplink all arrive late
    await _slot();
    try {
      http.Response r;
      try {
        r = await _client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 40));
      } on Object catch (e) {
        // the home address can't be reached any more: the same picture over the internet
        final public = App.api.canonical(url);
        if (public == url || !(e is SocketException || e is http.ClientException)) rethrow;
        App.api.dropLan();
        r = await _client.get(Uri.parse(public), headers: headers).timeout(const Duration(seconds: 40));
      }
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

/// Width / height of a JPEG or PNG from its header; null when it can't tell.
double? imageAspect(Uint8List b) {
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {  // PNG: IHDR
    final d = ByteData.sublistView(b);
    final w = d.getUint32(16), h = d.getUint32(20);
    return h == 0 ? null : w / h;
  }
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
      i += m == 0xFF ? 1 : 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    // SOF0..SOF15, not DHT (C4), JPG (C8), DAC (CC)
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      final h = (b[i + 5] << 8) | b[i + 6], w = (b[i + 7] << 8) | b[i + 8];
      return h == 0 ? null : w / h;
    }
    i += 2 + len;
  }
  return null;
}

/// One 16:9 picture (uncensored studios, FC2, digital-only releases), with no front half
/// to show - unlike a sleeve (back + spine + front: a DVD's ~1.49:1, a Blu-ray's ~1.83:1).
bool isOnePicture(double? aspect) => aspect != null && (aspect - 16 / 9).abs() <= 0.025;

class NetImage extends StatefulWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.decodeWidth, this.alignment = Alignment.center, this.poster = false});

  final String url;
  final BoxFit fit;
  final Alignment alignment;
  final int? decodeWidth;

  /// In a portrait slot: a wide picture is shown whole over a blurred copy of
  /// itself instead of having a strip cut out of it.
  final bool poster;

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
    if (widget.poster && isOnePicture(imageAspect(b))) {
      return Stack(fit: StackFit.expand, children: [
        ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: ColorFiltered(
              colorFilter: const ColorFilter.mode(Color(0x59000000), BlendMode.darken),
              child: Image.memory(b, fit: BoxFit.cover, cacheWidth: 160, gaplessPlayback: true),
            ),
          ),
        ),
        Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: widget.decodeWidth == null ? null : widget.decodeWidth! * 2),
      ]);
    }
    return Image.memory(
      b,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      cacheWidth: widget.decodeWidth,
      frameBuilder: (context, child, frame, sync) {
        return sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child);
      },
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
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, height: 1.3),
    ),
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
    this.corner = const [],
    this.cover = false,
    this.onTap,
  });

  final String image;
  final String code;
  final String subtitle;
  final List<Widget> badges;

  /// Lower right: my marks (♥ ★ 已看).
  final List<Widget> corner;

  /// A JavDB cover: the whole sleeve, of which the right half is the front.
  final bool cover;
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
                      NetImage(widget.image, decodeWidth: widget.cover ? 720 : 360, alignment: widget.cover ? Alignment.centerRight : Alignment.center, poster: true),
                      Positioned(left: 7, top: 7, right: 7, child: Wrap(spacing: 4, runSpacing: 4, children: widget.badges)),
                      if (widget.corner.isNotEmpty)
                        Positioned(right: 7, bottom: 7, child: Row(mainAxisSize: MainAxisSize.min, spacing: 3, children: widget.corner)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: _hover ? accent : p.text),
            ),
            const SizedBox(height: 2),
            Text(
              widget.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
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
        if (onRetry != null) ...[const SizedBox(height: 14), FilledButton.tonal(onPressed: onRetry, child: const Text('重试'))],
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: p.muted.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: p.muted)),
        ],
      ),
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
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
      ),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[Icon(icon, size: 15, color: p.muted), const SizedBox(width: 6)],
                    Text(e.value),
                  ],
                ),
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

/// Frosted glass behind the phone's status bar, for a page that scrolls up under it
/// (place it last in a Stack). Nothing where there is no status bar.
class StatusBarGlass extends StatelessWidget {
  const StatusBarGlass({super.key});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return const SizedBox.shrink();
    final p = Palette.of(context);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: top,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: ColoredBox(color: p.bg.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}

/// ♥ / ★n / 已看 for a poster's corner.
List<Widget> markBadges(LibraryItem it) => [
  if (it.fav) const _Mark('♥', color: Color(0xFFFF5A62)),
  if (it.rating > 0) _Mark('★${it.rating}'),
  if (it.watched) const _Mark('已看'),
];

class _Mark extends StatelessWidget {
  const _Mark(this.text, {this.color = Colors.white});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: const Color(0xA6000000), borderRadius: BorderRadius.circular(9)),
    child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, height: 1.35)),
  );
}
