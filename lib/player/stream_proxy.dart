import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Hosts of the 115 CDN, the only upstream this proxy takes over.
final _cdn115 = RegExp(r'115cdn\.(net|com)|115\.com|anxia\.com|115vod\.com', caseSensitive: false);

/// Asks JavHub for the CDN redirect only: no connection accounting, no
/// relaying through the NAS, just the 302 (and the file size).
const javResolveHeader = 'X-Jav-Resolve';

/// A loopback range proxy in front of the 115 CDN, so mpv never talks to it
/// directly.
///
/// 115 allows 2 connections per client IP per file and keeps counting a closed
/// one for 30-60 s, while mpv opens a new connection for every seek and reads
/// the file's index at the end before playing. Through this proxy mpv's
/// connections end on 127.0.0.1; upstream there are at most [maxUpstream]
/// keep-alive connections fetching fixed-size chunks, so a seek only changes
/// which chunk is fetched next. A "pmt" refusal is waited out instead of
/// reaching mpv, which would take it for the end of the file. The video still
/// goes CDN -> this device; nothing passes through the NAS.
///
/// Speed: a chunk's bytes go to mpv as they arrive (mpv waits for the CDN's
/// first byte, not for a whole chunk); read-ahead never takes the last free
/// connection, so a seek starts at once; and [prepare] (the movie's page)
/// resolves the link and fetches the file's start and end - where an MP4's
/// index usually is - before 播放 is pressed.
class JavStreamProxy {
  JavStreamProxy({
    this.chunkSize = 2 << 20,
    this.cacheBytes = 96 << 20,
    this.maxUpstream = 2,
    this.readAhead = 3,
    this.userAgent = 'JavHub-desktop/1.0 (libmpv)',
    this.pmtWait = const Duration(seconds: 90),
    bool Function(Uri location)? isCloud,
  }) : _isCloud = isCloud ?? ((u) => _cdn115.hasMatch(u.host));

  static final instance = JavStreamProxy();

  final int chunkSize;
  final int cacheBytes;

  /// The most of a file's index [prepare] fetches ahead.
  static const maxIndex = 24 << 20;
  final int maxUpstream;
  final int readAhead;

  /// The CDN link is signed for the User-Agent it was resolved with, so the
  /// resolve and every chunk request use this one.
  final String userAgent;

  /// How long a chunk keeps retrying while 115 answers "pmt" (too many
  /// connections) before giving up.
  final Duration pmtWait;
  final bool Function(Uri) _isCloud;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final HttpClient _client = HttpClient()
    // Idle keep-alive connections are kept, so pausing and seeking don't
    // close (and so re-open) upstream connections.
    ..idleTimeout = const Duration(seconds: 120)
    ..autoUncompress = false;
  final _sessions = LinkedHashMap<String, _Session>();
  int _nextId = 0;

  /// Sessions made ahead of time, by origin URL: [wrap] takes one over.
  final _prepared = LinkedHashMap<String, Future<_Session?>>();
  static const _preparedFor = Duration(minutes: 10);

  // Upstream slots: chunk requests a player waits for go first, newest first
  // (after a seek only the new position matters); read-ahead only takes a
  // slot when another one stays free for the next seek.
  int _busy = 0;
  final _waiters = <_Waiter>[];

  /// Upstream requests currently running (for tests and diagnostics).
  int get activeUpstream => _busy;

  /// Resolves [url] and fetches the file's first chunk - and with [tail], its
  /// last ones (an MP4 whose index is at the end needs them before playing) -
  /// so that a [wrap] soon after starts at once. Never throws.
  void prepare(String url, {Map<String, String> headers = const {}, bool tail = true}) {
    final origin = _origin(url);
    if (origin == null) return;
    _prepared.remove(url);
    // (marked as such: JavHub does not count getting ready as watching)
    _prepared[url] = _open(origin, {...headers, 'X-Jav-Prefetch': '1'}).then((s) async {
      if (s == null) return null;
      s.prepared = DateTime.now();
      final size = s.size;
      if (tail && size != null) {
        final last = (size - 1) ~/ chunkSize;
        // Where the index (moov) starts: right after the media data, whose size the
        // file's first boxes tell. A long 4K movie's index is ~12 MB - all of it is
        // read before the first frame, so all of it is fetched now (up to [maxIndex]).
        final first = await _chunk(s, 0, demand: true);
        await first?.whenDone.timeout(const Duration(seconds: 30));
        final moov = first == null ? null : mp4IndexStart(first.bytes(), size);
        final from = moov != null && size - moov <= maxIndex ? moov ~/ chunkSize : last - 1;
        for (var i = last; i >= math.max(1, from); i--) {
          // (as a demand: read-ahead would not take the slot the first chunk leaves)
          unawaited(_chunk(s, i, demand: true).then((c) => c?.whenDone).catchError((_) => null));
        }
      }
      return s;
    }).catchError((_) => null);
    while (_prepared.length > 4) {
      _prepared.remove(_prepared.keys.first);
    }
  }

  /// The URL to give mpv for [url]: a loopback URL when [url] redirects to
  /// the 115 CDN, else [url] itself. Never throws.
  Future<String> wrap(String url, {Map<String, String> headers = const {}}) async {
    try {
      final origin = _origin(url);
      if (origin == null) return url;
      _Session? session;
      final ready = _prepared.remove(url);
      trace('wrap: ${ready != null ? 'prepared' : 'cold'}');
      if (ready != null) {
        final s = await ready.timeout(const Duration(seconds: 30), onTimeout: () => null);
        if (s != null && DateTime.now().difference(s.prepared ?? DateTime(0)) < _preparedFor) session = s;
      }
      session ??= await _open(origin, headers);
      trace('wrap: ready (size ${session?.size})');
      if (session == null) return url;
      final server = await _ensureServer();
      final id = '${++_nextId}';
      _sessions[id] = session;
      while (_sessions.length > 3) {
        _sessions.remove(_sessions.keys.first);
      }
      return 'http://127.0.0.1:${server.port}/s/$id/${origin.pathSegments.isEmpty ? 'video' : origin.pathSegments.last}';
    } catch (_) {
      return url;
    }
  }

  Uri? _origin(String url) {
    final origin = Uri.tryParse(url);
    if (origin == null || (!origin.isScheme('http') && !origin.isScheme('https'))) return null;
    final path = origin.path.toLowerCase();
    // JavHub's 115 player route (and the Emby gateway's stream route)
    if (!(path.contains('/play/ol/') || path.contains('/videos/')) || path.endsWith('.m3u8')) return null;
    return origin;
  }

  /// A session on the CDN link of [origin], its first chunk on the way and
  /// the file's size known; null when [origin] does not lead to 115.
  Future<_Session?> _open(Uri origin, Map<String, String> headers) async {
    final cdn = await _resolve(origin, headers).timeout(const Duration(seconds: 8));
    trace('resolved');
    if (cdn == null) return null;
    final s = _Session(origin: origin, headers: headers, cdn: cdn);
    // The first chunk tells the size and type, and is what mpv reads first.
    final first = await _chunk(s, 0, demand: true);
    await first!.headers.timeout(const Duration(seconds: 30));
    if (s.size == null) await first.whenDone.timeout(const Duration(seconds: 30));
    return s.size == null ? null : s;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    _client.close(force: true);
  }

  // ---------------- upstream ----------------

  Future<Uri?> _resolve(Uri origin, Map<String, String> headers) async {
    final req = await _client.getUrl(origin);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    req.headers
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
      ..set(javResolveHeader, '1');
    final resp = await req.close();
    final location = resp.headers.value(HttpHeaders.locationHeader);
    await resp.drain<void>().catchError((_) {});
    if (!resp.isRedirect || location == null) return null;
    final target = origin.resolve(location);
    return _isCloud(target) ? target : null;
  }

  Future<bool> _acquire({required bool demand, required bool Function() alive, bool urgent = false}) async {
    if (_busy < (demand || urgent ? maxUpstream : maxUpstream - 1)) {
      _busy++;
      return true;
    }
    if (!demand) return false;
    final waiter = _Waiter(alive);
    _waiters.add(waiter);
    return waiter.done.future; // true: the slot was handed over by _release
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeLast();
      if (w.alive()) {
        w.done.complete(true);
        return;
      }
      w.done.complete(false); // its reader is gone (mpv seeked away)
    }
    _busy--;
  }

  /// Chunk [index] of [s]: from the cache, an identical download already
  /// running, or a new one (whose bytes arrive in the returned chunk as they
  /// come). Null only when no slot was free (read-ahead) or the reader left.
  Future<_Chunk?> _chunk(_Session s, int index, {required bool demand, bool Function()? alive, bool urgent = false}) async {
    final cached = s.cache.remove(index);
    if (cached != null) {
      s.cache[index] = cached; // most recently used
      return _Chunk.done(index, cached);
    }
    final running = s.inflight[index];
    if (running != null) return running;
    if (s.size != null && index * chunkSize >= s.size!) return _Chunk.done(index, Uint8List(0));
    if (!await _acquire(demand: demand, alive: alive ?? () => true, urgent: urgent)) return null;
    // While this waited for a slot, someone else may have fetched it.
    final cachedNow = s.cache[index];
    final runningNow = s.inflight[index];
    if (cachedNow != null || runningNow != null) {
      _release();
      return runningNow ?? _Chunk.done(index, cachedNow!);
    }
    final c = _Chunk(index);
    s.inflight[index] = c;
    unawaited(_download(s, c).whenComplete(() {
      _release();
      s.inflight.remove(index);
      if (c.error == null) {
        final data = c.bytes();
        s.cache[index] = data;
        s.cachedBytes += data.length;
        while (s.cachedBytes > cacheBytes && s.cache.length > 1) {
          final oldest = s.cache.keys.first;
          s.cachedBytes -= s.cache.remove(oldest)!.length;
        }
      }
    }));
    return c;
  }

  Future<void> _download(_Session s, _Chunk c) async {
    final start = c.index * chunkSize;
    final deadline = DateTime.now().add(pmtWait);
    var failures = 0;
    var resolves = 0;
    try {
      while (true) {
        // after a broken connection, on from what already arrived
        final from = start + c.length;
        final end = s.size == null ? start + chunkSize - 1 : math.min(start + chunkSize, s.size!) - 1;
        if (from > end) break;
        try {
          final req = await _client.getUrl(s.cdn);
          req.followRedirects = true;
          req.headers
            ..set(HttpHeaders.userAgentHeader, userAgent)
            ..set(HttpHeaders.rangeHeader, 'bytes=$from-$end');
          final resp = await req.close().timeout(const Duration(seconds: 20));
          trace('chunk ${c.index}: HTTP ${resp.statusCode}');
          if (resp.statusCode == HttpStatus.partialContent || resp.statusCode == HttpStatus.ok) {
            final total = RegExp(r'/(\d+)$').firstMatch(resp.headers.value(HttpHeaders.contentRangeHeader) ?? '');
            if (total != null) s.size = int.parse(total[1]!);
            if (resp.statusCode == HttpStatus.ok) s.size ??= resp.contentLength >= 0 ? resp.contentLength : null;
            s.contentType ??= resp.headers.contentType?.toString();
            c.gotHeaders();
            final want = math.min(end, (s.size ?? end + 1) - 1) - from + 1;
            var skip = resp.statusCode == HttpStatus.ok ? from : 0; // a whole-file answer
            var got = 0;
            // Read to the end, so the keep-alive connection can be reused.
            await for (final d in resp.timeout(const Duration(seconds: 30))) {
              var part = d is Uint8List ? d : Uint8List.fromList(d);
              if (skip > 0) {
                final n = math.min(skip, part.length);
                skip -= n;
                part = Uint8List.sublistView(part, n);
              }
              final take = math.min(part.length, want - got);
              if (take > 0) {
                c.add(take == part.length ? part : Uint8List.sublistView(part, 0, take));
                got += take;
              }
            }
            trace('chunk ${c.index}: done');
            if (got >= want) break;
            throw const SocketException('short read');
          }
          final body = await utf8.decodeStream(resp).catchError((_) => '');
          if (resp.statusCode == HttpStatus.forbidden && body.contains('pmt')) {
            // Too many connections for this file right now: wait it out.
            if (DateTime.now().isAfter(deadline)) throw _CdnRefused('115 pmt: $body');
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if ((resp.statusCode == HttpStatus.forbidden || resp.statusCode == HttpStatus.notFound ||
                  resp.statusCode == HttpStatus.gone) &&
              resolves < 2) {
            // The signed link expired: ask the gateway for a fresh one.
            resolves++;
            s.cdn = await _resolve(s.origin, s.headers) ?? s.cdn;
            continue;
          }
          throw _CdnRefused('CDN HTTP ${resp.statusCode}');
        } on _CdnRefused {
          rethrow;
        } catch (_) {
          // Network trouble (reset, timeout ...): retry a few times.
          if (++failures > 3) rethrow;
          await Future<void>.delayed(Duration(seconds: failures));
        }
      }
      c.finish();
    } catch (e) {
      c.finish(e);
    }
  }

  // ---------------- loopback server ----------------

  Future<HttpServer> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(server);
    return _starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((s) {
      _server = s;
      s.listen((req) => unawaited(_serve(req)), onError: (_) {});
      return s;
    });
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      final s = seg.length >= 2 && seg[0] == 's' ? _sessions[seg[1]] : null;
      final size = s?.size;
      if (s == null || size == null) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      var start = 0;
      var end = size - 1;
      final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (range != null) {
        if (range[1]!.isEmpty && range[2]!.isNotEmpty) {
          start = math.max(0, size - int.parse(range[2]!)); // suffix range
        } else {
          start = int.tryParse(range[1]!) ?? 0;
          if (range[2]!.isNotEmpty) end = math.min(end, int.parse(range[2]!));
        }
        if (start >= size) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      }
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, s.contentType ?? 'video/mp4');
      res.contentLength = end - start + 1;
      if (req.method == 'HEAD') return;

      // mpv reads a file through one connection at a time: a new request
      // means it seeked, and whatever the older ones still wanted is moot.
      // (Writing to a connection mpv closed does not reliably fail, so
      // without this an old reader could keep both upstream slots busy.)
      trace('mpv reads ${req.headers.value(HttpHeaders.rangeHeader)} (chunk ${start ~/ chunkSize})');
      final reader = _Reader();
      for (final old in s.readers) {
        old.alive = false;
      }
      s.readers.add(reader);
      unawaited(res.done.then((_) {}, onError: (_) {}).whenComplete(() => reader.alive = false));
      bool alive() => reader.alive;
      void ahead(int index) {
        // Keep the next chunks coming while mpv chews on this one. Normally one
        // connection stays free for a seek; when less than two chunks are ready
        // ahead (a high bitrate, or just after a seek) read-ahead may take it too.
        var ready = 0;
        while (ready < readAhead && (s.cache.containsKey(index + ready + 1) || s.inflight.containsKey(index + ready + 1))) {
          ready++;
        }
        for (var a = 1; a <= readAhead; a++) {
          unawaited(_chunk(s, index + a, demand: false, urgent: ready < 2).catchError((_) => null));
        }
      }

      try {
        var pos = start;
        while (pos <= end && reader.alive) {
          final index = pos ~/ chunkSize;
          final c = await _chunk(s, index, demand: true, alive: alive);
          if (c == null || !reader.alive) break;
          ahead(index);
          var offset = pos - index * chunkSize;
          while (reader.alive && pos <= end) {
            if (offset < c.length) {
              final data = c.read(offset, end - pos + 1);
              res.add(data);
              await res.flush();
              offset += data.length;
              pos += data.length;
              ahead(index);
              continue;
            }
            if (c.isDone) break;
            await c.changed;
          }
          if (c.error != null) throw c.error!;
          if (c.isDone && offset >= c.length && c.length < chunkSize) break; // end of the file
        }
      } finally {
        reader.alive = false;
        s.readers.remove(reader);
      }
    } catch (_) {
      // mpv closed the connection, or the CDN failed for good.
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// One chunk on its way: the bytes that arrived so far, and a signal for more.
class _Chunk {
  _Chunk(this.index);

  _Chunk.done(this.index, Uint8List data) {
    if (data.isNotEmpty) _parts.add(data);
    length = data.length;
    isDone = true;
    _headers.complete();
    _whenDone.complete();
  }

  final int index;
  final _parts = <Uint8List>[];
  int length = 0;
  bool isDone = false;
  Object? error;
  var _changed = Completer<void>();
  final _headers = Completer<void>();
  final _whenDone = Completer<void>();

  /// More bytes arrived, or the download ended.
  Future<void> get changed => _changed.future;

  /// The CDN answered (the file's size is known).
  Future<void> get headers => _headers.future;
  Future<void> get whenDone => _whenDone.future;

  void _notify() {
    final c = _changed;
    _changed = Completer<void>();
    c.complete();
  }

  void gotHeaders() {
    if (!_headers.isCompleted) _headers.complete();
    _notify();
  }

  void add(Uint8List d) {
    _parts.add(d);
    length += d.length;
    _notify();
  }

  void finish([Object? e]) {
    isDone = true;
    error = e;
    if (!_headers.isCompleted) e == null ? _headers.complete() : _headers.completeError(e);
    if (e == null) {
      _whenDone.complete();
    } else {
      _whenDone.completeError(e);
      unawaited(_whenDone.future.catchError((_) {}));
      unawaited(_headers.future.catchError((_) {}));
    }
    _notify();
  }

  /// Up to [max] bytes from [offset] (offset < length).
  Uint8List read(int offset, int max) {
    var skip = offset;
    for (final p in _parts) {
      if (skip >= p.length) {
        skip -= p.length;
        continue;
      }
      return Uint8List.sublistView(p, skip, math.min(p.length, skip + max));
    }
    return Uint8List(0);
  }

  Uint8List bytes() {
    if (_parts.length == 1) return _parts.first;
    final b = BytesBuilder(copy: false);
    _parts.forEach(b.add);
    return b.takeBytes();
  }
}

class _Waiter {
  _Waiter(this.alive);

  final bool Function() alive;
  final done = Completer<bool>();
}

class _Reader {
  bool alive = true;
}

/// The CDN said no for good (as opposed to a network error worth retrying).
class _CdnRefused implements Exception {
  _CdnRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Session {
  _Session({required this.origin, required this.headers, required this.cdn});

  final Uri origin;
  final Map<String, String> headers;
  Uri cdn;
  int? size;
  String? contentType;
  DateTime? prepared;
  final cache = LinkedHashMap<int, Uint8List>();
  int cachedBytes = 0;
  final inflight = <int, _Chunk>{};
  final readers = <_Reader>[];
}

/// Where an MP4's index (moov) starts when it comes after the media data, read off
/// the file's first boxes ([head]); null when the index is at the start or it can't
/// tell (not an MP4).
int? mp4IndexStart(Uint8List head, int size) {
  var p = 0;
  while (p + 8 <= head.length) {
    var n = head[p] << 24 | head[p + 1] << 16 | head[p + 2] << 8 | head[p + 3];
    final type = String.fromCharCodes(head, p + 4, p + 8);
    var header = 8;
    if (n == 1) {
      // a 64-bit size (a large mdat)
      if (p + 16 > head.length) return null;
      n = 0;
      for (var i = 8; i < 16; i++) {
        n = n * 256 + head[p + i];
      }
      header = 16;
    } else if (n == 0) {
      n = size - p; // to the end of the file
    }
    if (type == 'moov') return null; // index first: nothing to fetch from the end
    if (type == 'mdat') return p + n < size ? p + n : null;
    if (n < header) return null;
    p += n;
  }
  return null;
}

/// --dart-define=JAVHUB_TRACE=true: the steps of starting / seeking a video, with
/// their times, in javhub_trace.log in the temp directory (to see where time goes).
const _tracing = bool.fromEnvironment('JAVHUB_TRACE');
final _traceStart = DateTime.now();

void trace(String what) {
  if (!_tracing) return;
  final ms = DateTime.now().difference(_traceStart).inMilliseconds;
  try {
    File('${Directory.systemTemp.path}${Platform.pathSeparator}javhub_trace.log').writeAsStringSync('$ms $what\n', mode: FileMode.append);
  } catch (_) {}
}
