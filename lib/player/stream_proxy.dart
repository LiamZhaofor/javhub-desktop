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

/// Asks JavHub for a new CDN link instead of the one it kept (that one failed).
const javFreshHeader = 'X-Jav-Fresh';

/// A loopback range proxy in front of the 115 CDN, so mpv never talks to it
/// directly.
///
/// What 115's CDN does (measured 2026-11): one file takes at most 2 requests at
/// a time from one IP address - a third is refused with 403 "pmt" - while idle
/// keep-alive connections and finished requests don't count, and a request
/// whose connection is dropped half way stops counting at once. A request waits
/// ~100-400 ms for its first byte. Connections differ a lot, and each stays as
/// it is: most run at ~4-7 MB/s, now and then one at 20-30 (or all at the few
/// MB/s 115 allows an account it is slowing down); now and then a new one takes
/// seconds to open.
///
/// So mpv's reads end here, on 127.0.0.1, and upstream at most [maxUpstream]
/// requests per file fetch stretches of ~0.35 s each on the connection they
/// get (up to [runChunks] chunks), each request going on the fastest idle
/// connection. Connections are kept: a seek lets the requests about to end
/// finish - what mpv now waits for goes on whichever brings it soonest - so the
/// fast ones, done first and taken up most, stay; only one that would still
/// take long, is stuck, or crawls is dropped (closing its connection, which
/// frees 115's slot). Bytes go to mpv as they arrive, each checked to belong
/// where it is put. A "pmt" refusal is waited out instead of reaching mpv,
/// which would take it for the end of the file. The video still goes CDN ->
/// this device; nothing passes through the NAS.
///
/// [prepare] (the movie's page) resolves the link and fetches the file's start
/// and end - where an MP4's index usually is - before 播放 is pressed, and
/// resolved links are kept for an hour: playing a movie again does not wait
/// for JavHub at all.
class JavStreamProxy {
  JavStreamProxy({
    this.chunkSize = 2 << 20,
    this.cacheBytes = 96 << 20,
    this.maxUpstream = 2,
    this.readAhead = 16,
    this.runChunks = 8,
    this.userAgent = 'JavHub-desktop/1.0 (libmpv)',
    this.pmtWait = const Duration(seconds: 90),
    bool Function(Uri location)? isCloud,
  }) : _isCloud = isCloud ?? ((u) => _cdn115.hasMatch(u.host));

  static final instance = JavStreamProxy();

  /// What the cache keeps and requests are cut along.
  final int chunkSize;
  final int cacheBytes;

  /// The most of a file's index [prepare] fetches ahead.
  static const maxIndex = 24 << 20;

  /// Requests on one file at the same time (115 refuses a third).
  final int maxUpstream;

  /// Chunks kept coming ahead of where mpv reads.
  final int readAhead;

  /// The most chunks one request asks for (fewer on a slower connection, near
  /// the end, or before a chunk that is already here).
  final int runChunks;

  /// The CDN link is signed for the User-Agent it was resolved with, so the
  /// resolve and every chunk request use this one.
  final String userAgent;

  /// How long a request keeps retrying while 115 answers "pmt" (too many
  /// connections) before giving up.
  final Duration pmtWait;
  final bool Function(Uri) _isCloud;

  HttpServer? _server;
  Future<HttpServer>? _starting;

  /// For JavHub (the resolve); the CDN gets [_cdn].
  final HttpClient _client = HttpClient()
    ..idleTimeout = const Duration(seconds: 120)
    ..autoUncompress = false;
  final _cdn = _CdnClient();
  final _sessions = LinkedHashMap<String, _Session>();
  int _nextId = 0;

  /// Sessions made ahead of time, by origin URL: [wrap] takes one over.
  final _prepared = LinkedHashMap<String, Future<_Session?>>();
  static const _preparedFor = Duration(minutes: 10);

  /// CDN links by origin URL. 115's links stay good for days; one that fails
  /// anyway is asked for again.
  final _links = LinkedHashMap<String, _Link>();
  static const _linkFor = Duration(hours: 1);

  /// Resolves on their way, by origin URL (two requests finding the link
  /// expired ask JavHub once).
  final _resolving = <String, Future<_Link?>>{};

  int _active = 0;

  /// The CDN's address last time: a connection to it is opened while JavHub is
  /// still being asked for the link (TLS takes ~150 ms).
  Uri? _lastCdn;

  /// Upstream requests currently running (for tests and diagnostics).
  int get activeUpstream => _active;

  /// Resolves [url] and fetches the file's first chunk - and with [tail], its
  /// last ones (an MP4 whose index is at the end needs them before playing) -
  /// so that a [wrap] soon after starts at once. Never throws.
  void prepare(String url, {Map<String, String> headers = const {}, bool tail = true}) {
    final origin = _origin(url);
    if (origin == null) return;
    final old = _prepared.remove(url);
    if (old != null) unawaited(old.then((s) => s == null ? null : _dispose(s)));
    // (marked as such: JavHub does not count getting ready as watching)
    _prepared[url] = _open(origin, {...headers, 'X-Jav-Prefetch': '1'}, url).then((s) {
      if (s == null) return null;
      s.prepared = DateTime.now();
      if (tail) unawaited(_fetchIndex(s).catchError((_) {}));
      return s;
    }).catchError((_) => null);
    while (_prepared.length > 4) {
      unawaited(_prepared.remove(_prepared.keys.first)!.then((s) => s == null ? null : _dispose(s)));
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
      trace('wrap: ${ready != null ? 'prepared' : _links.containsKey(url) ? 'link kept' : 'cold'}');
      if (ready != null) {
        final s = await ready.timeout(const Duration(seconds: 30), onTimeout: () => null);
        if (s != null && DateTime.now().difference(s.prepared ?? DateTime(0)) < _preparedFor) {
          session = s;
        } else if (s != null) {
          _dispose(s);
        }
      }
      session ??= await _open(origin, headers, url);
      trace('wrap: ready (size ${session?.size})');
      if (session == null) return url;
      final server = await _ensureServer();
      final id = '${++_nextId}';
      _sessions[id] = session;
      while (_sessions.length > 3) {
        _dispose(_sessions.remove(_sessions.keys.first)!);
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

  /// A session on the CDN link of [origin] with its first chunk on the way;
  /// null when [origin] does not lead to 115. When JavHub tells the size along
  /// with the link this does not wait for the CDN at all.
  Future<_Session?> _open(Uri origin, Map<String, String> headers, String key) async {
    final warm = _lastCdn;
    if (warm != null && !_links.containsKey(key)) _cdn.warm(warm);
    final link = await _link(key, origin, headers);
    trace('resolved');
    if (link == null) return null;
    _lastCdn = link.cdn;
    final s = _Session(origin: origin, headers: headers, key: key, cdn: link.cdn)
      ..size = link.size
      ..contentType = _typeOf(origin.path);
    _want(s, 0, 0); // what mpv reads first
    if (s.size == null) {
      final first = s.inflight[0]!;
      await first.headers.timeout(const Duration(seconds: 30));
      if (s.size == null) await first.whenDone.timeout(const Duration(seconds: 30));
    }
    return s.size == null ? null : s;
  }

  /// The end of the file, where an MP4 often keeps its index (moov) - read
  /// before the first frame: the last chunk at once, next to the first one,
  /// and the rest of the index (one request) once the first chunk tells where
  /// it starts. A long 4K movie's index is ~12 MB.
  Future<void> _fetchIndex(_Session s) async {
    final size = s.size!;
    final last = (size - 1) ~/ chunkSize;
    if (last < 1) return;
    _want(s, last, last);
    final first = _chunkFor(s, 0) ?? s.inflight[0];
    if (first == null) return;
    await first.whenDone.timeout(const Duration(seconds: 30));
    final moov = mp4IndexStart(first.bytes(), size);
    final from = moov != null && size - moov <= maxIndex ? moov ~/ chunkSize : last - 1;
    if (from < last && !s.closed) _want(s, math.max(1, from), last - 1);
  }

  Future<void> close() async {
    for (final s in _sessions.values) {
      _dispose(s);
    }
    _sessions.clear();
    for (final p in _prepared.values) {
      unawaited(p.then((s) => s == null ? null : _dispose(s)));
    }
    _prepared.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    _client.close(force: true);
    _cdn.close();
  }

  // ---------------- the link ----------------

  Future<_Link?> _link(String key, Uri origin, Map<String, String> headers, {bool fresh = false}) async {
    final kept = _links[key];
    if (!fresh && kept != null && DateTime.now().difference(kept.at) < _linkFor) return kept;
    final running = _resolving[key];
    if (running != null) return running;
    // (a slow first connection to JavHub over the internet can take a few seconds:
    // giving up early would leave mpv on its own with 115's limit)
    final f = _resolve(origin, headers, fresh: fresh).timeout(const Duration(seconds: 20)).then((link) {
      _links.remove(key);
      if (link != null) {
        _links[key] = link;
        while (_links.length > 64) {
          _links.remove(_links.keys.first);
        }
      }
      return link;
    });
    _resolving[key] = f;
    try {
      return await f;
    } finally {
      if (identical(_resolving[key], f)) _resolving.remove(key);
    }
  }

  Future<_Link?> _resolve(Uri origin, Map<String, String> headers, {bool fresh = false}) async {
    final req = await _client.getUrl(origin);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    req.headers
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
      ..set(javResolveHeader, '1');
    if (fresh) req.headers.set(javFreshHeader, '1');
    final resp = await req.close();
    final location = resp.headers.value(HttpHeaders.locationHeader);
    final size = int.tryParse(resp.headers.value('X-Jav-Size') ?? '');
    await resp.drain<void>().catchError((_) {});
    if (!resp.isRedirect || location == null) return null;
    final target = origin.resolve(location);
    return _isCloud(target) ? _Link(target, size != null && size > 0 ? size : null, DateTime.now()) : null;
  }

  // ---------------- what is fetched ----------------

  int? _last(_Session s) => s.size == null ? null : math.max(0, (s.size! - 1) ~/ chunkSize);

  /// Bytes in chunk [i] (the last one is shorter).
  int _lengthOf(_Session s, int i) => s.size == null ? chunkSize : math.max(0, math.min(chunkSize, s.size! - i * chunkSize));

  /// Chunk [i] when it is here or on its way.
  _Chunk? _chunkFor(_Session s, int i) {
    final cached = s.cache.remove(i);
    if (cached != null) {
      s.cache[i] = cached; // most recently used
      return _Chunk.done(i, cached);
    }
    final c = s.inflight[i];
    return c != null && (c.owner != null || c.isDone) ? c : null;
  }

  bool _covered(_Session s, int i) {
    if (s.cache.containsKey(i)) return true;
    final c = s.inflight[i];
    return c != null && (c.owner != null || c.isDone);
  }

  /// Chunks [from]-[to] wanted without a player reading them (a movie's page).
  void _want(_Session s, int from, int to) {
    s.pinned.add([from, to]);
    _pump(s);
  }

  /// Decides what is fetched: where the player reads and a stretch ahead of it,
  /// then what a movie's page asked for; requests nobody needs any more are
  /// dropped.
  void _pump(_Session s, {bool settled = false}) {
    if (s.closed) return;
    final last = _last(s);
    _Reader? reader;
    for (final r in s.readers.reversed) {
      if (r.alive) {
        reader = r;
        break;
      }
    }
    // (a stretch the page asked for is done once all of it came - once: what the
    // cache let go of since, mpv no longer needs from there)
    s.pinned.removeWhere((w) {
      for (var i = w[0]; i <= w[1]; i++) {
        if (!s.cache.containsKey(i) && !s.fetched.contains(i) && (last == null || i <= last)) return false;
      }
      return true;
    });
    final wants = <List<int>>[
      if (reader != null) [reader.chunk, last == null ? reader.chunk + readAhead : math.min(last, reader.chunk + readAhead)],
      ...s.pinned,
    ];
    bool wanted(int i) => wants.any((w) => i >= w[0] && i <= w[1]);
    if (reader == null && !settled && (s.transfers.isNotEmpty || s.inflight.isNotEmpty)) {
      // No player reading: mpv opens its next connection before it closes the old
      // one, so it is leaving (or between two requests). Give it a moment before
      // dropping anything.
      s.settle ??= Timer(const Duration(milliseconds: 300), () {
        s.settle = null;
        _pump(s, settled: true);
      });
    } else {
      for (final t in [...s.transfers]) {
        if (wanted(t.at)) continue;
        // Only one that still takes long is dropped. Dropping one closes its
        // connection, and connections differ a lot and each stays as it is (most
        // run at ~6 MB/s, now and then one at 20-30): let end, it goes on where mpv
        // now reads, and the fast ones - done first, so taken up most - are kept.
        if ((_msLeft(t) ?? 600) > 1500) _abort(t);
      }
      final stale = [
        for (final e in s.inflight.entries)
          if (e.value.owner == null && !wanted(e.key)) e.key
      ];
      for (final i in stale) {
        s.inflight.remove(i)!.poke();
      }
    }
    // What mpv waits for (after a seek) goes where it comes soonest: on a
    // connection free now, or on one of the requests on their way once that ends
    // (a fast one about to end beats a slow one free now). With no room, it waits
    // for the one that brings it soonest, unless even that takes over 1.5 s:
    // then the request that would take longest makes room.
    final waiting = reader != null && !_covered(s, reader.chunk) && (last == null || reader.chunk <= last);
    _Transfer? soon;
    if (waiting) {
      const ttfb = 220.0; // ms, for a new place in the file
      final full = s.transfers.length >= maxUpstream;
      final now = _cdn.idleRate(s.cdn) ?? s.rate ?? _typicalRate;
      var best = full ? 1500.0 : ttfb + chunkSize / now;
      for (final t in s.transfers) {
        // (one asked for after mpv came here is not waited for - waiting for those,
        // one after the other, mpv could wait for ever)
        if (!t.born.isBefore(reader.born) || _slow(t)) continue;
        final left = _msLeft(t);
        final r = _rateOf(t);
        if (left == null || r == null) continue;
        final cost = left + ttfb + chunkSize / r;
        if (cost < best) {
          best = cost;
          soon = t;
        }
      }
      if (soon == null && full) {
        _Transfer? drop;
        var most = -1.0;
        for (final t in s.transfers) {
          var left = _msLeft(t) ?? double.infinity;
          if (_fastConn(t)) left /= 2; // (a fast connection is kept rather)
          if (left > most) {
            most = left;
            drop = t;
          }
        }
        if (drop != null) _abort(drop);
      }
    }
    for (final w in wants) {
      var i = w[0];
      while (i <= w[1] && s.transfers.length < maxUpstream && (last == null || i <= last)) {
        if (_covered(s, i) || (soon != null && i == reader!.chunk)) {
          i++;
          continue;
        }
        // One request at a time is "quick" - a single chunk - and the other runs
        // long: the long one keeps the bytes coming with few waits for a first
        // byte (~100-250 ms each), and the quick one's connection is almost always
        // about to be free and warm for a seek.
        final quick = !s.transfers.any((t) => t.quick);
        // The other one is as long as ~0.35 s (cut to fit the connection it gets,
        // see [_fit]) - the wait for its first byte is then a small part of it, and
        // at a seek it is about to end, so its connection is kept - except for the
        // first chunks of a read (a seek, the start): mpv needs those before it
        // plays, and one chunk per request has both connections bring them at once
        // (on one long request, a slow connection would hold them all up).
        var run = 1;
        if (!quick && !(reader != null && w[0] == reader.chunk && i <= reader.first + _seekChunks)) {
          final rate = s.rate;
          run = rate == null ? runChunks : math.max(1, math.min(runChunks, (rate * 350 / chunkSize).round()));
        }
        var j = i;
        // (it stops before a chunk an earlier request left part done: the answer
        // brings each chunk from its start, so that one's bytes would come twice,
        // the second time after the first - it goes on from where it stopped, in a
        // request of its own)
        while (j + 1 <= w[1] &&
            j + 1 - i < run &&
            (last == null || j + 1 <= last) &&
            !_covered(s, j + 1) &&
            s.inflight[j + 1] == null) {
          j++;
        }
        // After a seek mpv reads from somewhere inside a chunk: the request starts
        // there, not at the chunk's start (that would be up to 2 MB to wait for).
        final from = reader != null && i == reader.chunk && s.inflight[i] == null
            ? reader.offset - reader.offset % _skipStep
            : 0;
        _start(s, i, j, base: from, quick: quick);
        i = j + 1;
      }
    }
  }

  /// A connection this slow (bytes per ms, ~1.5 MB/s) while another one to the
  /// same file runs 5 times as fast is crawling.
  static const _crawlRate = 1.5 * 1048.576;

  /// How long [t] still takes (ms), at the speed it has had - one still waiting
  /// for its first byte on a warm connection: ~0.15 s for it, then the speed this
  /// file gets; null: no telling (on a cold one it may wait ~0.4 s, then start
  /// slow).
  double? _msLeft(_Transfer t) {
    final now = t.watch.elapsedMilliseconds;
    final first = t.firstByte;
    if (first == null && !t.warm) return null;
    final rate = _rateOf(t) ?? t.s.rate; // bytes per ms
    if (rate == null || rate <= 0) return null;
    final have = t.s.inflight[t.at]?.length ?? 0;
    final left = (t.last - t.at) * chunkSize + math.max(0, _lengthOf(t.s, t.at) - have);
    return (first == null ? math.max(0, 150 - now) : 0) + left / rate;
  }

  /// Bytes per ms [t] gets: since its first byte, or what its connection got last.
  double? _rateOf(_Transfer t) {
    final first = t.firstByte;
    final now = t.watch.elapsedMilliseconds;
    if (first != null && now - first >= 50 && t.got >= (256 << 10)) return t.got / (now - first);
    return t.connRate;
  }

  /// [t] is on one of the fast connections.
  bool _fastConn(_Transfer t) {
    final r = _rateOf(t);
    return r != null && _cdn.isFast(t.s.cdn, r);
  }

  /// Bytes per ms a connection usually gets, before any was measured (~6 MB/s).
  static const _typicalRate = 6 * 1048.576;

  /// A request that starts inside a chunk starts on a multiple of this.
  static const _skipStep = 16 << 10;

  /// The chunks after where a read begins (a seek) that go one per request.
  static const _seekChunks = 3;

  /// [t] runs far slower than this file's requests usually do.
  bool _slow(_Transfer t) {
    final first = t.firstByte;
    final good = t.s.goodRate;
    if (first == null || good == null) return false;
    final ms = t.watch.elapsedMilliseconds - first;
    return ms >= 100 && t.got / ms * 3 < good;
  }

  void _start(_Session s, int a, int b, {int base = 0, bool quick = false}) {
    final t = _Transfer(s, a, b, quick: quick);
    for (var i = a; i <= b; i++) {
      // (a chunk an earlier request left half done is taken up where it stopped)
      (s.inflight[i] ??= _Chunk(i, base: i == a ? base : 0)).owner = t;
    }
    s.transfers.add(t);
    _active++;
    s.notify();
    unawaited(_run(t));
    // a seek then finds connections ready (it needs two: both requests start anew)
    _cdn.warm(s.cdn, spares: maxUpstream);
    s.watchdog ??= Timer.periodic(const Duration(milliseconds: 500), (_) => _watch(s));
  }

  /// Now and then a connection crawls (~0.5 MB/s) while another one to the same
  /// file runs at 10+ - one long request on it would hold mpv up for half a
  /// minute. Such a one is dropped and goes on, from where it stopped, on another
  /// connection. Compared with the other request at the same moment (two of them
  /// share the line, each getting half, which is no crawl), or - alone - with
  /// what this file usually gets. (When all of them are slow - 115 slowing the
  /// account down - nothing is gained by that, and none is.)
  void _watch(_Session s) {
    if (s.closed || s.transfers.isEmpty) {
      s.watchdog?.cancel();
      s.watchdog = null;
      return;
    }
    for (final t in s.transfers) {
      if (t.firstByte == null) continue;
      final rate = (t.got - t.lastGot) / 500;
      t.lastGot = t.got;
      t.recent = t.recent < 0 ? rate : t.recent * 0.5 + rate * 0.5;
    }
    if (_unstick(s, _readerOf(s))) return;
    final good = s.goodRate;
    for (final t in [...s.transfers]) {
      final first = t.firstByte;
      if (first == null || t.watch.elapsedMilliseconds - first < 1500 || t.recent >= _crawlRate) continue;
      final others = [for (final o in s.transfers) if (o != t && o.firstByte != null) o.recent];
      final crawling = others.isNotEmpty
          ? others.any((r) => r >= t.recent * 5)
          : good != null && t.recent < good / 10 && t.recent < _crawlRate * 2 / 3;
      if (!crawling || !_mayRestart(s)) continue;
      trace('chunks ${t.at}-${t.last}: crawling (${(t.recent / 1048.576).toStringAsFixed(1)} MB/s), on a new connection');
      _abort(t); // (what it got stays; the rest is asked for again)
    }
  }

  /// mpv waits on a chunk whose request is stuck - its connection still opening
  /// (that has taken seconds at times), or far slower than the file's requests
  /// usually are: it goes again on another connection (one that just came free
  /// is warm), keeping what arrived. True when it did.
  bool _unstick(_Session s, _Reader? reader) {
    if (reader == null) return false;
    final c = s.inflight[reader.chunk];
    final t = c?.owner;
    if (c == null || t == null || t.finished || t.at != reader.chunk || c.length > reader.offset) return false;
    final stuck = t.firstByte == null ? t.watch.elapsedMilliseconds > 500 : _slow(t);
    if (!stuck || !_mayRestart(s)) return false;
    trace('chunks ${t.at}-${t.last}: mpv waits, ${t.firstByte == null ? 'no answer yet' : 'slow'}: on another connection');
    _abort(t);
    return true;
  }

  /// A restart allowed (4 per half minute at most).
  bool _mayRestart(_Session s) {
    final since = s.restartsSince;
    if (since == null || DateTime.now().difference(since) > const Duration(seconds: 30)) {
      s.restartsSince = DateTime.now();
      s.restarts = 0;
    }
    if (s.restarts >= 4) return false;
    s.restarts++;
    return true;
  }

  _Reader? _readerOf(_Session s) {
    for (final r in s.readers.reversed) {
      if (r.alive) return r;
    }
    return null;
  }

  /// [t] ends where ~0.35 s at [rate] (bytes per ms) takes it; the chunks after
  /// are free for others.
  void _fit(_Transfer t, double rate) {
    final s = t.s;
    final n = (rate * 350 / chunkSize).round();
    final last = t.at + (n < 1 ? 1 : n) - 1;
    if (last >= t.last) return;
    for (var i = last + 1; i <= t.last; i++) {
      final c = s.inflight[i];
      if (c == null || c.owner != t) continue;
      c.owner = null;
      if (c.length == c.base) s.inflight.remove(i);
      c.poke();
    }
    t.last = last;
    scheduleMicrotask(() => _pump(s));
  }

  /// Drops [t] at once: its connection closes, so 115 stops counting it.
  void _abort(_Transfer t) {
    if (t.finished) return;
    t.s.dropped = DateTime.now();
    t.response?.abort();
    t.cancel?.call(); // still waiting for its first byte: 115 counts it all the same
    trace('chunks ${t.at}-${t.last}: dropped');
    _finish(t);
  }

  void _finish(_Transfer t) {
    if (t.finished) return;
    t.finished = true;
    final s = t.s;
    s.transfers.remove(t);
    _active--;
    for (var i = t.at; i <= t.last; i++) {
      final c = s.inflight[i];
      if (c == null || c.owner != t) continue;
      c.owner = null;
      if (c.length == c.base) s.inflight.remove(i); // (nothing in it yet)
      c.poke(); // whoever waits on it looks again
    }
    s.notify();
    _pump(s);
  }

  /// Drops chunk [c] (begun part way), and its request if that is still on it.
  void _rebase(_Session s, _Chunk c) {
    final t = c.owner;
    if (t != null && t.at == c.index) _abort(t);
    if (identical(s.inflight[c.index], c)) {
      s.inflight.remove(c.index);
      c.owner = null;
    }
    c.poke();
    _pump(s);
  }

  void _dispose(_Session s) {
    if (s.closed) return;
    s.closed = true;
    s.settle?.cancel();
    s.settle = null;
    s.watchdog?.cancel();
    s.watchdog = null;
    for (final t in [...s.transfers]) {
      _abort(t);
    }
    for (final r in s.readers) {
      r.alive = false;
    }
    for (final c in s.inflight.values) {
      c.poke();
    }
    s.notify();
  }

  /// One request: chunks [_Transfer.at]-[_Transfer.last] in one range, each
  /// chunk filled (and readable) as its bytes arrive.
  Future<void> _run(_Transfer t) async {
    final s = t.s;
    final deadline = DateTime.now().add(pmtWait);
    var failures = 0;
    var resolves = 0;
    var refusals = 0;
    var redirects = 0;
    final watch = Stopwatch()..start();
    var bytes = 0;
    try {
      while (!t.finished && t.at <= t.last) {
        final c = s.inflight[t.at];
        if (c == null || c.owner != t) break;
        // after a broken connection: on from what already arrived
        final from = t.at * chunkSize + c.length;
        var end = (t.last + 1) * chunkSize - 1;
        if (s.size != null) end = math.min(end, s.size! - 1);
        if (from > end) {
          _complete(t); // whole already, or past the end of the file
          continue;
        }
        try {
          final asked = watch.elapsedMilliseconds;
          final used = s.cdn;
          final resp = await _cdn.get(used, from, end, userAgent, onConn: (cancel, warm, rate) {
            t.warm = warm;
            t.connRate = rate;
            if (t.finished) {
              cancel();
            } else {
              t.cancel = cancel;
            }
            // (a long one is as long as ~0.35 s on the connection it got)
            if (!t.quick && rate != null && !t.finished) _fit(t, rate);
            return math.min(end, (t.last + 1) * chunkSize - 1);
          });
          t.cancel = null;
          t.reused = resp.reused;
          if (t.finished) {
            resp.abort();
            break;
          }
          t.response = resp;
          trace('chunks ${t.at}-${t.last}: HTTP ${resp.status} after ${watch.elapsedMilliseconds - asked} ms${resp.reused ? '' : ' (new connection)'}');
          if (resp.status == HttpStatus.partialContent || resp.status == HttpStatus.ok) {
            final total = RegExp(r'/(\d+)$').firstMatch(resp.header('content-range') ?? '');
            if (total != null) s.size = int.parse(total[1]!);
            if (resp.status == HttpStatus.ok) s.size ??= resp.contentLength;
            final type = resp.header('content-type');
            if (type != null && type.startsWith('video/')) s.contentType = type;
            c.gotHeaders();
            t.pos = from;
            t.stop = false;
            var skip = resp.status == HttpStatus.ok ? from : 0; // a whole-file answer
            await resp.body((d) {
              if (t.finished) return false;
              var part = d;
              if (skip > 0) {
                final n = math.min(skip, part.length);
                skip -= n;
                if (n == part.length) return true;
                part = Uint8List.sublistView(part, n);
              }
              t.firstByte ??= t.watch.elapsedMilliseconds;
              final before = t.got;
              t.got += part.length;
              if (before < (1 << 20) && t.got >= (1 << 20)) {
                trace('chunks ${t.at}-${t.last}: 1 MiB in ${t.watch.elapsedMilliseconds - t.firstByte!} ms after the first byte${resp.reused ? '' : ' (new connection)'}');
              }
              bytes += part.length;
              // (a 206 ends where the range ends: read to its end, so the connection
              // can be used again; a whole-file 200 is cut off)
              return _feed(t, part) || (resp.status == HttpStatus.partialContent && !t.finished && !t.stop);
            });
            if (t.finished) break;
            if (t.at > t.last || (s.size != null && t.at * chunkSize >= s.size!)) break;
            if (t.stop) {
              if (++failures > 3) throw StateError('answers do not fit the chunks');
              continue; // (asked again at once, from where the chunk stands)
            }
            throw const SocketException('short read');
          }
          final body = await resp.text();
          if (resp.status == HttpStatus.forbidden && body.contains('pmt')) {
            // 115 counts more requests on this file than it allows (another player
            // at this address, or one it has not let go of yet): wait it out.
            if (DateTime.now().isAfter(deadline)) throw _CdnRefused('115 pmt: $body');
            refusals++;
            await Future<void>.delayed(Duration(milliseconds: math.min(2000, refusals == 1 ? 150 : 400 * refusals)));
            continue;
          }
          final location = resp.header('location');
          if (resp.status >= 300 && resp.status < 400 && location != null && redirects < 3) {
            redirects++;
            s.cdn = s.cdn.resolve(location);
            continue;
          }
          if ((resp.status == HttpStatus.forbidden || resp.status == HttpStatus.notFound || resp.status == HttpStatus.gone) &&
              resolves < 2) {
            // The signed link expired: ask the gateway for a fresh one (unless
            // another request of this file just did).
            if (s.cdn != used) continue;
            resolves++;
            final link = await _link(s.key, s.origin, s.headers, fresh: true);
            if (link != null) s.cdn = link.cdn;
            continue;
          }
          if (resp.status == HttpStatus.requestedRangeNotSatisfiable) {
            final total = RegExp(r'/(\d+)$').firstMatch(resp.header('content-range') ?? '');
            if (total != null) s.size = int.parse(total[1]!);
            while (!t.finished && t.at <= t.last) {
              _complete(t); // past the end: nothing more to come
            }
            break;
          }
          throw _CdnRefused('CDN HTTP ${resp.status}');
        } on _CdnRefused {
          rethrow;
        } catch (_) {
          // Network trouble (reset, timeout ...): retry a few times.
          if (t.finished) break;
          if (++failures > 3) rethrow;
          await Future<void>.delayed(Duration(seconds: failures));
        }
      }
    } catch (e) {
      if (!t.finished) {
        final c = s.inflight[t.at];
        if (c != null && c.owner == t) {
          s.inflight.remove(t.at);
          c.owner = null;
          c.finish(e);
        }
        s.pinned.clear(); // the page's prefetch gives up; a player asks again
      }
    } finally {
      final ms = watch.elapsedMilliseconds;
      if (bytes > 0) trace('chunks to ${t.at - 1}: ${(bytes / (1 << 20)).toStringAsFixed(1)} MiB in $ms ms');
      final first = t.finished ? null : t.firstByte; // (a dropped one tells nothing)
      // (only warm connections tell the speed: a new one spends its first ~0.3 s
      // speeding up)
      if (t.quick && t.reused && first != null && t.got >= (1 << 20) && t.watch.elapsedMilliseconds > first) {
        final r = t.got / (t.watch.elapsedMilliseconds - first);
        final old = s.quickRate;
        s.quickRate = old == null ? r : old * 0.6 + r * 0.4;
      }
      if (first != null && t.got >= (1 << 20) && t.watch.elapsedMilliseconds > first) {
        final r = t.got / (t.watch.elapsedMilliseconds - first);
        final was = s.rate;
        s.rate = was == null ? r : was * 0.7 + r * 0.3;
      }
      if (first != null && t.got >= (2 << 20) && t.watch.elapsedMilliseconds > first) {
        final r = t.got / (t.watch.elapsedMilliseconds - first);
        final old = s.goodRate;
        // (a slow one counts less: it should not drag the yardstick down)
        s.goodRate = old == null ? r : (r >= old ? old * 0.5 + r * 0.5 : old * 0.85 + r * 0.15);
      }
      _finish(t);
    }
  }

  /// Bytes of [t]'s response into its chunks; false once it has all it asked for.
  bool _feed(_Transfer t, Uint8List d) {
    final s = t.s;
    var off = 0;
    while (off < d.length) {
      if (t.finished || t.at > t.last) return false;
      final c = s.inflight[t.at];
      if (c == null || c.owner != t) return false;
      if (t.at * chunkSize + c.length != t.pos) {
        // bytes that do not go where this chunk stands (they would garble the
        // movie): asked for again from there
        t.stop = true;
        return false;
      }
      final room = _lengthOf(s, t.at) - c.length;
      final take = math.min(room, d.length - off);
      if (take > 0) {
        c.add(off == 0 && take == d.length ? d : Uint8List.sublistView(d, off, off + take));
        off += take;
        t.pos += take;
      }
      if (c.length >= _lengthOf(s, t.at)) _complete(t);
    }
    return !t.finished && t.at <= t.last;
  }

  /// [t]'s current chunk is whole: into the cache, and on to the next one.
  void _complete(_Transfer t) {
    final s = t.s;
    final i = t.at++;
    final c = s.inflight[i];
    if (c == null || c.owner != t) return;
    c.owner = null;
    c.finish();
    s.fetched.add(i);
    if (c.base == 0) {
      s.inflight.remove(i);
      _store(s, i, c.bytes());
    }
    // (one begun part way is not cached: it stays here, done, while mpv reads it)
    s.notify();
  }

  void _store(_Session s, int i, Uint8List data) {
    s.cache.remove(i);
    s.cache[i] = data;
    s.cachedBytes += data.length;
    if (s.cachedBytes <= cacheBytes) return;
    _Reader? reader;
    for (final r in s.readers.reversed) {
      if (r.alive) {
        reader = r;
        break;
      }
    }
    while (s.cachedBytes > cacheBytes && s.cache.length > 1) {
      // the oldest one the player does not read next
      var victim = s.cache.keys.first;
      if (reader != null) {
        for (final k in s.cache.keys) {
          if (k < reader.chunk || k > reader.chunk + readAhead) {
            victim = k;
            break;
          }
        }
      }
      s.cachedBytes -= s.cache.remove(victim)!.length;
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

  /// Chunk [i] for [r]: here, or on its way (started now if need be); null
  /// once [r] is gone.
  Future<_Chunk?> _await(_Session s, int i, _Reader r) async {
    while (r.alive && !s.closed) {
      final last = _last(s);
      if (last != null && i > last) return _Chunk.done(i, Uint8List(0));
      final c = _chunkFor(s, i);
      if (c != null) return c;
      _pump(s);
      final now = _chunkFor(s, i);
      if (now != null) return now;
      await s.changed.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    return null;
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      final s = seg.length >= 2 && seg[0] == 's' ? _sessions[seg[1]] : null;
      final size = s?.size;
      if (s == null || size == null || s.closed) {
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
      final reader = _Reader(start ~/ chunkSize, start % chunkSize);
      for (final old in s.readers) {
        old.alive = false;
      }
      s.readers.add(reader);
      unawaited(res.done.then((_) {}, onError: (_) {}).whenComplete(() {
        if (!reader.alive) return;
        reader.alive = false;
        _pump(s);
      }));
      _pump(s);
      var first = true;
      try {
        var pos = start;
        while (pos <= end && reader.alive && !s.closed) {
          final index = pos ~/ chunkSize;
          reader.offset = pos - index * chunkSize;
          if (index != reader.chunk) {
            reader.chunk = index;
            _pump(s); // keep the stretch ahead coming
          }
          final c = await _await(s, index, reader);
          if (c == null || !reader.alive) break;
          var offset = pos - index * chunkSize;
          if (offset < c.base) {
            // a chunk begun after where this read starts (a seek just behind the last
            // one): fetch it again from here
            _rebase(s, c);
            continue;
          }
          while (reader.alive && pos <= end) {
            if (offset < c.length) {
              final data = c.read(offset, end - pos + 1);
              if (first) trace('first bytes for mpv: ${data.length} B');
              res.add(data);
              await res.flush();
              if (first) {
                first = false;
                trace('mpv gets its first bytes');
              }
              offset += data.length;
              pos += data.length;
              continue;
            }
            // whole, or its request was dropped: look again
            if (c.isDone || c.owner == null) break;
            await c.changed;
          }
          if (c.error != null) throw c.error!;
          if (c.isDone && offset >= c.length && c.length < chunkSize) break; // end of the file
        }
      } finally {
        reader.alive = false;
        s.readers.remove(reader);
        _pump(s);
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

String? _typeOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return const {
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'ts': 'video/mp2t',
    'avi': 'video/x-msvideo',
    'mov': 'video/quicktime',
    'wmv': 'video/x-ms-wmv',
    'flv': 'video/x-flv',
  }[path.substring(dot + 1).toLowerCase()];
}

class _Link {
  _Link(this.cdn, this.size, this.at);

  final Uri cdn;
  final int? size;
  final DateTime at;
}

/// One chunk on its way: the bytes that arrived so far, and a signal for more.
class _Chunk {
  _Chunk(this.index, {this.base = 0}) : length = base;

  _Chunk.done(this.index, Uint8List data) : base = 0 {
    if (data.isNotEmpty) _parts.add(data);
    length = data.length;
    isDone = true;
    _headers.complete();
    _whenDone.complete();
  }

  final int index;

  /// Bytes before this offset are not in it (a request that began part way).
  final int base;

  /// The request filling it; null when none is (yet, or any more).
  _Transfer? owner;
  final _parts = <Uint8List>[];

  /// Its bytes run up to here (from [base]).
  int length = 0;
  bool isDone = false;
  Object? error;
  var _changed = Completer<void>();
  final _headers = Completer<void>();
  final _whenDone = Completer<void>();

  /// More bytes arrived, the download ended, or its request was dropped.
  Future<void> get changed => _changed.future;

  /// The CDN answered (the file's size is known).
  Future<void> get headers => _headers.future;
  Future<void> get whenDone => _whenDone.future;

  void poke() {
    final c = _changed;
    _changed = Completer<void>();
    c.complete();
  }

  void gotHeaders() {
    if (!_headers.isCompleted) _headers.complete();
    poke();
  }

  void add(Uint8List d) {
    _parts.add(d);
    length += d.length;
    poke();
  }

  void finish([Object? e]) {
    isDone = true;
    error = e;
    if (!_headers.isCompleted) e == null ? _headers.complete() : _headers.completeError(e);
    if (!_whenDone.isCompleted) {
      if (e == null) {
        _whenDone.complete();
      } else {
        _whenDone.completeError(e);
        unawaited(_whenDone.future.catchError((_) {}));
        unawaited(_headers.future.catchError((_) {}));
      }
    }
    poke();
  }

  /// Up to [max] bytes from [offset] (base <= offset < length).
  Uint8List read(int offset, int max) {
    var skip = offset - base;
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

/// One range request upstream, filling chunks [at]..[last] in order.
class _Transfer {
  _Transfer(this.s, this.at, this.last, {required this.quick});

  final _Session s;
  int at;
  int last;
  bool quick;
  bool finished = false;
  final born = DateTime.now();

  /// Its answer is dropped where it stands (its connection closes).
  bool stop = false;

  /// Where in the file the next byte of its answer belongs.
  int pos = 0;

  /// Its request went on a connection that is up to speed, which last got this
  /// (bytes per ms; null: not measured).
  bool warm = false;
  double? connRate;

  /// Its connection had carried a request before (it is up to speed).
  bool reused = false;
  final watch = Stopwatch()..start();

  /// When its first body byte came (ms on [watch]), and how many came since.
  int? firstByte;
  int got = 0;

  /// For the watchdog: [got] at its last look, and the speed since (bytes/ms).
  int lastGot = 0;
  double recent = -1;
  _CdnResponse? response;

  /// Closes the connection of the request on its way (before its answer came).
  void Function()? cancel;
}

class _Reader {
  _Reader(this.chunk, this.offset) : first = chunk;

  /// Where it reads now: the chunk, and the offset in it.
  int chunk;
  int offset;

  /// The chunk it began in, and when.
  final int first;
  final born = DateTime.now();
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
  _Session({required this.origin, required this.headers, required this.key, required this.cdn});

  final Uri origin;
  final Map<String, String> headers;
  final String key;
  Uri cdn;
  int? size;
  String? contentType;
  DateTime? prepared;
  bool closed = false;
  final cache = LinkedHashMap<int, Uint8List>();
  int cachedBytes = 0;

  /// Chunks on their way (with an owner), or left half done by a dropped request.
  final inflight = <int, _Chunk>{};
  final transfers = <_Transfer>{};
  final readers = <_Reader>[];

  /// Chunk ranges wanted with no player reading them (a movie's page).
  final pinned = <List<int>>[];

  /// Chunks that came whole (for [pinned]).
  final fetched = <int>{};
  Timer? settle;

  /// Bytes per ms the quick requests have been getting (after their first byte).
  double? quickRate;


  /// Bytes per ms one request of this file gets (after its first byte), lately.
  double? rate;

  /// When a request of this file was last dropped.
  DateTime? dropped;

  /// Bytes per ms requests of this file usually get; crawling ones are restarted
  /// (a few times per half minute at most).
  double? goodRate;
  Timer? watchdog;
  int restarts = 0;
  DateTime? restartsSince;
  var _changed = Completer<void>();

  /// A request started or ended, or a chunk came in.
  Future<void> get changed => _changed.future;

  void notify() {
    final c = _changed;
    _changed = Completer<void>();
    c.complete();
  }
}

// ---------------- the CDN's connections ----------------

/// Range requests to the CDN over keep-alive connections of its own: dart:io's
/// HttpClient cannot drop a response half way (cancelling one keeps the
/// connection reading in the background), and 115 counts a request for as long
/// as its connection carries it.
class _CdnClient {
  final _idle = <String, List<_CdnConn>>{};
  bool _closed = false;

  /// [onConn], once the connection is picked, gets a way to drop the request
  /// before its answer comes, whether the connection is up to speed (it carried
  /// an answer just before) and what it last got (bytes per ms), and says where
  /// the range ends.
  Future<_CdnResponse> get(Uri url, int from, int to, String userAgent,
      {int Function(void Function() cancel, bool warm, double? rate)? onConn}) async {
    final key = '${url.scheme}://${url.host}:${url.port}';
    for (var attempt = 0;; attempt++) {
      final pool = _idle[key];
      _CdnConn? reused;
      while (reused == null && pool != null && pool.isNotEmpty) {
        // The fastest one: connections differ a lot and each stays as it is (most
        // run at ~6 MB/s, now and then one at 20-30). One not measured yet - a
        // spare - counts as what one usually gets, so a slow one idle there is
        // passed over for a try of another. (Of equals, the last one back.)
        final typical = _typical[key] ?? 0;
        var c = pool.last;
        for (final o in pool.reversed) {
          if ((o.rate ?? typical) > (c.rate ?? typical)) c = o;
        }
        pool.remove(c);
        // (one idle for long may be dead without anyone saying so - a router
        // forgot it - and a request on it would wait for nothing)
        if (c.idleFor < const Duration(seconds: 10)) {
          reused = c;
        } else {
          c.destroy();
        }
      }
      final conn = reused ?? await _CdnConn.open(url);
      final end = onConn?.call(conn.destroy, reused != null && conn.answers > 0 && conn.idleFor < const Duration(milliseconds: 300), conn.rate) ?? to;
      try {
        // the CDN answers in ~0.1-0.4 s: a reused connection silent for longer is
        // taken for dead, and the request goes again on a new one
        final res = await conn
            .send(url, from, end, userAgent, onIdle: () => _park(key, conn))
            .timeout(Duration(seconds: reused != null ? 3 : 8));
        res.reused = reused != null;
        return res;
      } catch (e) {
        conn.destroy();
        if (reused != null && attempt == 0) continue; // the CDN had closed that idle one
        rethrow;
      }
    }
  }

  final _warming = <String, int>{};

  /// Opens a connection to [url]'s host ahead of time, unless one is idle
  /// already. (An idle connection costs nothing at 115.)
  void warm(Uri url, {int spares = 1}) {
    if (_closed) return;
    final key = '${url.scheme}://${url.host}:${url.port}';
    final pool = _idle[key];
    if (pool != null) {
      for (final c in [...pool]) {
        if (c.idleFor >= const Duration(seconds: 10)) c.destroy(); // (leaves the pool)
      }
    }
    final have = (_idle[key]?.length ?? 0) + (_warming[key] ?? 0);
    for (var i = have; i < spares; i++) {
      _warming[key] = (_warming[key] ?? 0) + 1;
      unawaited(_CdnConn.open(url).then((c) {
        _warming[key] = (_warming[key] ?? 1) - 1;
        if (_closed) return c.destroy();
        _park(key, c);
      }, onError: (_) {
        _warming[key] = (_warming[key] ?? 1) - 1;
      }));
    }
  }

  /// Bytes per ms: the fastest connection to a host lately (it fades, so a
  /// slower time of day soon sets it), and what one usually gets.
  final _best = <String, double>{};
  final _typical = <String, double>{};

  String _key(Uri url) => '${url.scheme}://${url.host}:${url.port}';

  /// What a request to [url] would get now: on the fastest idle connection, or
  /// (none) on a new one; null: no telling yet.
  double? idleRate(Uri url) {
    final key = _key(url);
    final typical = _typical[key];
    double? r;
    for (final c in _idle[key] ?? const <_CdnConn>[]) {
      final x = c.rate ?? typical;
      if (x != null && (r == null || x > r)) r = x;
    }
    return r ?? typical;
  }

  /// [rate] (bytes per ms) is that of one of the fast connections to [url].
  bool isFast(Uri url, double rate) {
    final key = _key(url);
    final best = _best[key], typical = _typical[key];
    return best != null && typical != null && rate >= best * 0.6 && rate >= typical * 1.5;
  }

  void _park(String key, _CdnConn c) {
    if (_closed) return c.destroy();
    final r = c.rate;
    if (r != null) {
      if (c.measured) {
        c.measured = false;
        final t = _typical[key];
        _typical[key] = t == null ? r : t * 0.8 + r * 0.2;
        _best[key] = math.max(r, (_best[key] ?? 0) * 0.9);
      }
    }
    final pool = _idle.putIfAbsent(key, () => []);
    pool.add(c);
    c.idle(() => pool.remove(c));
    while (pool.length > 4) {
      pool.removeAt(0).destroy();
    }
  }

  void close() {
    _closed = true;
    for (final pool in _idle.values) {
      for (final c in [...pool]) {
        c.destroy();
      }
    }
    _idle.clear();
  }
}

class _CdnConn {
  _CdnConn._(this._socket) {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = _socket.listen(_data, onError: _broken, onDone: () => _broken(const SocketException('closed by the CDN')));
  }

  static Future<_CdnConn> open(Uri url) async {
    const timeout = Duration(seconds: 10);
    final socket = url.isScheme('https')
        ? await SecureSocket.connect(url.host, url.port, timeout: timeout, supportedProtocols: const ['http/1.1'])
        : await Socket.connect(url.host, url.port, timeout: timeout);
    return _CdnConn._(socket);
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  bool _dead = false;

  /// Bytes per ms its last long answer came at (null: none yet), and whether the
  /// pool has not counted that one yet.
  double? rate;
  bool measured = false;

  /// Answers it carried.
  int answers = 0;
  Timer? _idleTimer;
  void Function()? _unpark;
  void Function()? _onIdle;
  Completer<_CdnResponse>? _head;
  final _headBytes = <int>[];
  _CdnResponse? _res;

  Future<_CdnResponse> send(Uri url, int from, int to, String userAgent, {required void Function() onIdle}) {
    if (_dead) return Future.error(const SocketException('connection closed'));
    _idleTimer?.cancel();
    _unpark = null;
    _onIdle = onIdle;
    final path = '${url.path.isEmpty ? '/' : url.path}${url.hasQuery ? '?${url.query}' : ''}';
    final host = url.hasPort ? '${url.host}:${url.port}' : url.host;
    _head = Completer<_CdnResponse>();
    _headBytes.clear();
    _socket.add(utf8.encode('GET $path HTTP/1.1\r\n'
        'Host: $host\r\n'
        'User-Agent: $userAgent\r\n'
        'Range: bytes=$from-$to\r\n'
        'Accept: */*\r\n'
        'Accept-Encoding: identity\r\n'
        'Connection: keep-alive\r\n\r\n'));
    return _head!.future;
  }

  final _idleWatch = Stopwatch();

  /// How long it has been back in the pool.
  Duration get idleFor => _idleWatch.elapsed;

  /// Back in the pool: closed after 30 s unused, or when the CDN closes it.
  void idle(void Function() unpark) {
    _unpark = unpark;
    _idleWatch
      ..reset()
      ..start();
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 30), destroy);
  }

  void _data(Uint8List d) {
    final head = _head;
    if (head != null) {
      final from = math.max(0, _headBytes.length - 3);
      _headBytes.addAll(d);
      var end = -1;
      for (var i = from; i + 3 < _headBytes.length; i++) {
        if (_headBytes[i] == 13 && _headBytes[i + 1] == 10 && _headBytes[i + 2] == 13 && _headBytes[i + 3] == 10) {
          end = i;
          break;
        }
      }
      if (end < 0) {
        if (_headBytes.length > 64 << 10) _broken(const FormatException('response head too long'));
        return;
      }
      _head = null;
      final lines = latin1.decode(_headBytes.sublist(0, end)).split('\r\n');
      final rest = Uint8List.fromList(_headBytes.sublist(end + 4));
      _headBytes.clear();
      final parts = lines.first.split(' ');
      final headers = <String, String>{};
      for (final l in lines.skip(1)) {
        final k = l.indexOf(':');
        if (k > 0) headers[l.substring(0, k).trim().toLowerCase()] = l.substring(k + 1).trim();
      }
      final res = _res = _CdnResponse(this, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0, headers);
      head.complete(res);
      if (!res.chunked && res._left == 0) {
        res._end(); // no body
      } else if (rest.isNotEmpty) {
        res._push(rest);
      }
      return;
    }
    final res = _res;
    if (res != null) {
      res._push(d);
    } else {
      destroy(); // bytes nobody asked for: this connection can't be trusted any more
    }
  }

  void _broken(Object e) {
    final head = _head;
    _head = null;
    if (head != null && !head.isCompleted) head.completeError(e);
    _res?._closed(e);
    destroy();
  }

  /// The response [r] ended: the connection is free for the next request.
  void _ended(_CdnResponse r, bool reusable) {
    if (_res != r) return;
    _res = null;
    if (reusable && !_dead) {
      _onIdle?.call();
    } else {
      destroy();
    }
  }

  void destroy() {
    if (_dead) return;
    _dead = true;
    _idleTimer?.cancel();
    _unpark?.call();
    _unpark = null;
    unawaited(_sub.cancel());
    _socket.destroy();
    final head = _head;
    _head = null;
    if (head != null && !head.isCompleted) head.completeError(const SocketException('dropped'));
    final res = _res;
    _res = null;
    res?._closed(const SocketException('dropped'));
  }
}

/// A CDN response; its body is read once, with [body] or [text].
class _CdnResponse {
  _CdnResponse(this._conn, this.status, this._headers) {
    chunked = (_headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked');
    contentLength = int.tryParse(_headers['content-length'] ?? '');
    keepAlive = (_headers['connection'] ?? '').toLowerCase() != 'close';
    _left = chunked ? 0 : contentLength ?? -1;
  }

  final _CdnConn _conn;
  final int status;
  final Map<String, String> _headers;

  /// It came over a connection opened before (for the trace).
  bool reused = false;
  late final bool chunked;
  int? contentLength;
  late final bool keepAlive;
  int _left = 0; // body bytes to come (-1: until the connection closes)
  bool _ended = false;
  bool _aborted = false;
  Object? _error;
  bool Function(Uint8List)? _onData;
  Completer<void>? _done;
  final _pending = <Uint8List>[];
  Timer? _stall;

  // chunked framing
  int _state = 0; // 0 size line, 1 data, 2 end of data, 3 trailer
  final _line = <int>[];
  int _chunkLeft = 0;

  String? header(String name) => _headers[name.toLowerCase()];

  /// Streams the body to [onData], which returns false to drop the rest
  /// (closing the connection). Completes when the body ended or was dropped.
  Future<void> body(bool Function(Uint8List) onData) {
    final done = _done = Completer<void>();
    _onData = onData;
    final pending = [..._pending];
    _pending.clear();
    for (final p in pending) {
      if (_aborted) break;
      if (!onData(p)) abort();
    }
    if (_error != null) {
      done.completeError(_error!);
    } else if (_ended) {
      if (!done.isCompleted) done.complete();
    } else {
      _watch();
    }
    return done.future;
  }

  Future<String> text() async {
    final b = BytesBuilder();
    await body((d) {
      if (b.length < 4096) b.add(d);
      return true;
    });
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  /// Drops the response and its connection.
  void abort() {
    if (_ended) return;
    _aborted = true;
    _ended = true;
    _stall?.cancel();
    _conn.destroy();
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  void _watch() {
    _stall?.cancel();
    // (10 s without a byte: the connection is gone; the request goes on from where
    // it stopped on a new one)
    _stall = Timer(const Duration(seconds: 10), () => _closed(TimeoutException('CDN stalled')));
  }

  void _push(Uint8List d) {
    if (_ended) return;
    if (_done != null) _watch();
    if (chunked) {
      _pushChunked(d);
      return;
    }
    if (_left < 0) {
      _deliver(d);
      return;
    }
    final take = math.min(_left, d.length);
    if (take > 0) _deliver(take == d.length ? d : Uint8List.sublistView(d, 0, take));
    _left -= take;
    if (_left == 0) _end();
  }

  void _pushChunked(Uint8List d) {
    var i = 0;
    while (i < d.length && !_ended) {
      switch (_state) {
        case 0:
        case 3:
          final b = d[i++];
          if (b == 10) {
            final line = latin1.decode(_line).trim();
            _line.clear();
            if (_state == 0) {
              final n = int.tryParse(line.split(';').first.trim(), radix: 16);
              if (n == null) {
                _closed(const FormatException('bad chunked body'));
                return;
              }
              if (n == 0) {
                _state = 3;
              } else {
                _chunkLeft = n;
                _state = 1;
              }
            } else if (line.isEmpty) {
              _end();
              return;
            }
          } else if (b != 13 && _line.length < 1024) {
            _line.add(b);
          }
        case 1:
          final take = math.min(_chunkLeft, d.length - i);
          _deliver(Uint8List.sublistView(d, i, i + take));
          i += take;
          _chunkLeft -= take;
          if (_chunkLeft == 0) _state = 2;
        case 2:
          if (d[i++] == 10) _state = 0;
      }
    }
  }

  final _clock = Stopwatch();
  int _bytes = 0;

  void _deliver(Uint8List p) {
    if (_aborted || p.isEmpty) return;
    if (_bytes == 0) _clock.start();
    _bytes += p.length;
    final on = _onData;
    if (on == null) {
      _pending.add(p);
    } else if (!on(p)) {
      abort();
    }
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _stall?.cancel();
    // how fast its connection is (connections differ, and each stays as it is)
    final us = _clock.elapsedMicroseconds;
    if (_bytes >= 1 << 20 && us > 0) {
      _conn.rate = _bytes / (us / 1000);
      _conn.measured = true;
    }
    _conn.answers++;
    _conn._ended(this, keepAlive);
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  /// The connection went away (or stalled) before the body ended.
  void _closed(Object e) {
    if (_ended) return;
    if (!chunked && _left < 0) {
      // a body that ends with its connection
      _ended = true;
      _stall?.cancel();
      _conn._ended(this, false);
      final d = _done;
      if (d != null && !d.isCompleted) d.complete();
      return;
    }
    _ended = true;
    _stall?.cancel();
    _error = e;
    _conn.destroy();
    final d = _done;
    if (d != null && !d.isCompleted) d.completeError(e);
  }
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
  // ignore: avoid_print
  print('javhub-trace $ms $what'); // (Android: logcat)
  try {
    File('${Directory.systemTemp.path}${Platform.pathSeparator}javhub_trace.log').writeAsStringSync('$ms $what\n', mode: FileMode.append);
  } catch (_) {}
}
