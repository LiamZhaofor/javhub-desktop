import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/player/stream_proxy.dart';

const _size = 10 * 1024 * 1024 + 12345;
const _ua = 'test-ua';

Uint8List _file() => Uint8List.fromList(List.generate(_size, (i) => (i * 31 + (i >> 11)) & 0xff));

/// A CDN with 115's rules: links bound to the User-Agent, and "pmt" 403 once
/// a file has more than 2 requests at the same time. A request stops counting
/// the moment its connection goes away, even while it still waits to answer
/// (dart:io's HttpServer can't tell, so this one is made of plain sockets).
class _FakeCdn {
  _FakeCdn(this.server, this.data);

  final ServerSocket server;
  final Uint8List data;
  int active = 0;
  int peak = 0;
  int requests = 0;
  int refusals = 0;
  int connections = 0;
  int forcePmt = 0; // answer the next N requests with "pmt"
  int crawl = 0; // send the next N answers at ~0.3 MB/s
  int hold = 0; // the next N requests hang for 5 s first (a connection that takes long to open)
  bool expired = false;
  Duration delay = const Duration(milliseconds: 20);
  Duration? trickle; // a slow CDN: this long per 64 KiB

  static Future<_FakeCdn> start(Uint8List data) async {
    final cdn = _FakeCdn(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), data);
    cdn.server.listen(cdn._connection);
    return cdn;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/file.mp4?t=1');

  void _connection(Socket socket) {
    connections++;
    var buf = <int>[];
    var open = true;
    void Function()? onGone;
    var queue = Future<void>.value();
    void gone() {
      open = false;
      onGone?.call();
      onGone = null;
    }

    socket.listen((d) {
      buf.addAll(d);
      while (true) {
        var end = -1;
        for (var i = 0; i + 3 < buf.length; i++) {
          if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
            end = i;
            break;
          }
        }
        if (end < 0) break;
        final head = latin1.decode(buf.sublist(0, end));
        buf = buf.sublist(end + 4);
        queue = queue.then((_) => open ? _answer(socket, head, () => open, (f) => onGone = f) : null).catchError((_) {});
      }
    }, onDone: gone, onError: (_) => gone());
  }

  Future<void> _answer(Socket socket, String head, bool Function() open, void Function(void Function()?) onGone) async {
    requests++;
    final lines = head.split('\r\n');
    final h = <String, String>{};
    for (final l in lines.skip(1)) {
      final k = l.indexOf(':');
      if (k > 0) h[l.substring(0, k).trim().toLowerCase()] = l.substring(k + 1).trim();
    }
    void reply(int status, String reason, Map<String, String> headers, List<int> body) {
      final b = StringBuffer('HTTP/1.1 $status $reason\r\n');
      headers.forEach((k, v) => b.write('$k: $v\r\n'));
      b.write('Content-Length: ${body.length}\r\n\r\n');
      socket.add(latin1.encode(b.toString()));
      if (body.isNotEmpty) socket.add(body);
    }

    if (h['user-agent'] != _ua || expired) {
      reply(403, 'Forbidden', {}, utf8.encode('{"message":"expired"}'));
      return;
    }
    // a request takes a moment to cross the network: by then the CDN has seen a
    // connection the client dropped just before (on loopback that can race)
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (hold > 0) {
      hold--;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (!open()) return;
    active++;
    peak = math.max(peak, active);
    var counted = true;
    void release() {
      if (counted) {
        counted = false;
        active--;
      }
    }

    onGone(release);
    try {
      if (active > 2 || forcePmt > 0) {
        if (forcePmt > 0) forcePmt--;
        refusals++;
        reply(403, 'Forbidden', {}, utf8.encode('{"message":"115 pmt 3-2","status":403}'));
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(h['range'] ?? '')!;
      final start = int.parse(m[1]!);
      final end = m[2]!.isEmpty ? data.length - 1 : math.min(int.parse(m[2]!), data.length - 1);
      await Future<void>.delayed(delay);
      if (!open()) return;
      final b = StringBuffer('HTTP/1.1 206 Partial Content\r\n')
        ..write('Content-Range: bytes $start-$end/${data.length}\r\n')
        ..write('Content-Type: video/mp4\r\n')
        ..write('Content-Length: ${end - start + 1}\r\n\r\n');
      socket.add(latin1.encode(b.toString()));
      final slow = crawl > 0;
      if (slow) crawl--;
      final t = slow ? const Duration(milliseconds: 200) : trickle;
      if (t == null) {
        socket.add(Uint8List.sublistView(data, start, end + 1));
        await socket.flush();
      } else {
        for (var p = start; p <= end && open(); p += 65536) {
          socket.add(Uint8List.sublistView(data, p, math.min(end + 1, p + 65536)));
          await socket.flush();
          await Future<void>.delayed(t);
        }
      }
    } finally {
      onGone(null);
      release();
    }
  }
}

/// The Emby gateway: 302 to the CDN for the resolve request, plain bytes for a local item.
/// With [size] it tells the file's size along with the link, as JavHub does.
Future<HttpServer> _gateway(_FakeCdn cdn, List<Map<String, String?>> seen, {int? size}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    seen.add({
      'path': req.uri.path,
      'resolve': req.headers.value(javResolveHeader),
      'fresh': req.headers.value(javFreshHeader),
      'token': req.headers.value('X-Emby-Token'),
      'ua': req.headers.value(HttpHeaders.userAgentHeader),
    });
    final res = req.response;
    if (req.uri.path.contains('/cloud')) {
      cdn.expired = false; // a fresh link
      res.statusCode = 302;
      res.headers.set(HttpHeaders.locationHeader, cdn.url.toString());
      if (size != null) res.headers.set('X-Jav-Size', '$size');
    } else {
      res.statusCode = 206;
      res.write('x');
    }
    await res.close();
  });
  return server;
}

Future<Uint8List> _get(String url, String range) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    expect(res.statusCode, 206);
    final b = BytesBuilder();
    await res.forEach(b.add);
    return b.takeBytes();
  } finally {
    client.close();
  }
}

void main() {
  test('115 streams play through the loopback proxy within the connection limit', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final seen = <Map<String, String?>>[];
    final gw = await _gateway(cdn, seen);
    final proxy = JavStreamProxy(
      chunkSize: 1 << 20,
      cacheBytes: 1 << 20, // one chunk: later reads must go to the CDN again
      userAgent: _ua,
      pmtWait: const Duration(seconds: 20),
      isCloud: (u) => u.port == cdn.server.port,
    );
    try {
      final origin = 'http://127.0.0.1:${gw.port}/emby/videos/cloud/stream.mp4?static=true';
      final local = await proxy.wrap(origin, headers: {'X-Emby-Token': 'tok'});
      expect(local, startsWith('http://127.0.0.1:'));
      expect(local, isNot(origin));
      expect(seen.single['resolve'], '1');
      expect(seen.single['token'], 'tok');
      expect(seen.single['ua'], _ua); // the link is signed for this UA

      // mpv opening a file: header, index at the end, playback, a seek. It reads
      // through one connection at a time (a new request ends the older one).
      final reads = <Uint8List>[];
      for (final range in [
        'bytes=0-',
        'bytes=${_size - 300000}-',
        'bytes=3000000-3999999',
        'bytes=7777777-',
      ]) {
        reads.add(await _get(local, range));
      }
      expect(reads[0], data);
      expect(reads[1], Uint8List.sublistView(data, _size - 300000));
      expect(reads[2], Uint8List.sublistView(data, 3000000, 4000000));
      expect(reads[3], Uint8List.sublistView(data, 7777777));
      expect(cdn.peak, lessThanOrEqualTo(2));
      expect(cdn.refusals, 0);

      // 115 still counting someone else's connections: waited out, not an error.
      cdn.forcePmt = 2;
      final again = await _get(local, 'bytes=9500000-9600000');
      expect(again, Uint8List.sublistView(data, 9500000, 9600001));
      expect(cdn.refusals, 2);

      // The signed link expired: the proxy asks the gateway for a new one (once,
      // and saying the kept one failed).
      cdn.expired = true;
      final fresh = await _get(local, 'bytes=200-299');
      expect(fresh, Uint8List.sublistView(data, 200, 300));
      expect(seen.length, 2);
      expect(seen.last['fresh'], '1');
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('a seek abandons the old read instead of queueing behind it', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    cdn.delay = const Duration(milliseconds: 150); // a real CDN's time to first byte
    final gw = await _gateway(cdn, []);
    final proxy = JavStreamProxy(
      chunkSize: 512 * 1024,
      userAgent: _ua,
      isCloud: (u) => u.port == cdn.server.port,
    );
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/emby/videos/cloud/stream.mp4');
      // mpv starts reading the whole file, takes a little and hangs up (a seek) - three times.
      for (final from in [0, 4000000, 8000000]) {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(local));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
        final res = await req.close();
        final got = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = res.listen((_) {
          if (!got.isCompleted) got.complete();
        });
        await got.future;
        await sub.cancel();
        client.close(force: true);
      }
      final watch = Stopwatch()..start();
      final tail = await _get(local, 'bytes=${_size - 100000}-');
      expect(tail, Uint8List.sublistView(data, _size - 100000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      // and the abandoned reads stopped pulling chunks from the CDN
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final settled = cdn.requests;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(cdn.requests, settled);
      expect(cdn.peak, lessThanOrEqualTo(2));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test("JavHub's own 115 route goes through the proxy too", () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final seen = <Map<String, String?>>[];
    final gw = await _gateway(cdn, seen);
    final proxy = JavStreamProxy(userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final origin = 'http://127.0.0.1:${gw.port}/play/ol/115/cloud/SSIS-469.mp4?mode=direct&relay=0';
      final local = await proxy.wrap(origin, headers: {'Cookie': 'jh=token'});
      expect(local, startsWith('http://127.0.0.1:'));
      expect(seen.single['path'], '/play/ol/115/cloud/SSIS-469.mp4');
      expect(seen.single['resolve'], '1');
      expect(await _get(local, 'bytes=1000-1999'), Uint8List.sublistView(data, 1000, 2000));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('other streams are left alone', () async {
    final cdn = await _FakeCdn.start(_file());
    final gw = await _gateway(cdn, []);
    final proxy = JavStreamProxy(userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = 'http://127.0.0.1:${gw.port}/emby/videos/local/stream.mp4';
      expect(await proxy.wrap(local), local); // no redirect
      final remote = 'http://192.0.2.1/emby/videos/x/master.m3u8';
      expect(await proxy.wrap(remote), remote); // HLS
      expect(await proxy.wrap('/media/file.mp4'), '/media/file.mp4');
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('bytes go to the player as they arrive, not a whole chunk later', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, []);
    final proxy = JavStreamProxy(chunkSize: 2 << 20, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/x.mp4');
      cdn.trickle = const Duration(milliseconds: 40); // a 2 MiB chunk takes ~1.3 s
      final client = HttpClient();
      final watch = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(local));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=6000000-');
      final res = await req.close();
      final first = Completer<Duration>();
      final b = BytesBuilder();
      late StreamSubscription<List<int>> sub;
      sub = res.listen((d) {
        if (!first.isCompleted) first.complete(watch.elapsed);
        b.add(d);
        if (b.length >= 3 << 20) unawaited(sub.cancel());
      });
      expect(await first.future, lessThan(const Duration(milliseconds: 600)));
      client.close(force: true);
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test("a movie's page prepares the stream: 播放 then needs no resolve and has the index", () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final seen = <Map<String, String?>>[];
    final gw = await _gateway(cdn, seen);
    final proxy = JavStreamProxy(chunkSize: 1 << 20, readAhead: 0, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final origin = 'http://127.0.0.1:${gw.port}/play/ol/115/cloud/ABF-217.mp4';
      proxy.prepare(origin, headers: {'Cookie': 'jh=token'});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final before = cdn.requests;
      final local = await proxy.wrap(origin, headers: {'Cookie': 'jh=token'});
      expect(seen, hasLength(1)); // resolved once, by prepare
      // the start and the index at the end are already here
      expect(await _get(local, 'bytes=0-99999'), Uint8List.sublistView(data, 0, 100000));
      expect(await _get(local, 'bytes=${_size - 200000}-'), Uint8List.sublistView(data, _size - 200000));
      expect(cdn.requests, before);
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('one request brings many chunks, and a second one runs beside it', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(chunkSize: 256 * 1024, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4');
      expect(await _get(local, 'bytes=0-'), data); // 41 chunks
      // a chunk per request (as before) would be 41 requests, each waiting for its first
      // byte (the first few of a read, and the quick ones, still go one by one)
      expect(cdn.requests, lessThan(20));
      expect(cdn.peak, 2);
      expect(cdn.refusals, 0);
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('a link is kept: playing the movie again does not ask JavHub', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final seen = <Map<String, String?>>[];
    final gw = await _gateway(cdn, seen, size: data.length);
    final proxy = JavStreamProxy(userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final origin = 'http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4';
      expect(await _get(await proxy.wrap(origin), 'bytes=0-999'), Uint8List.sublistView(data, 0, 1000));
      final again = await proxy.wrap(origin);
      expect(await _get(again, 'bytes=5000000-5000999'), Uint8List.sublistView(data, 5000000, 5001000));
      expect(seen, hasLength(1));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('with the size from JavHub, playing starts without waiting for the CDN', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    cdn.delay = const Duration(milliseconds: 600); // a slow first byte
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final watch = Stopwatch()..start();
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4');
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 400))); // mpv opens meanwhile
      expect(await _get(local, 'bytes=0-99999'), Uint8List.sublistView(data, 0, 100000));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('a seek inside a chunk is fetched from there, not from the chunk start', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cdn.trickle = const Duration(milliseconds: 20); // 64 KiB per 20 ms: 1.5 MB would take ~0.5 s
      final watch = Stopwatch()..start();
      final at = (3 << 21) + 1500000; // 1.5 MB into a 2 MB chunk
      expect(await _get(local, 'bytes=$at-${at + 9999}'), Uint8List.sublistView(data, at, at + 10000));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 300)));
      // and a seek just before it (inside the same chunk) still gets its bytes
      cdn.trickle = null;
      expect(await _get(local, 'bytes=${at - 300000}-${at - 290001}'), Uint8List.sublistView(data, at - 300000, at - 290000));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('a connection that crawls is replaced, and the read goes on from where it was', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(chunkSize: 512 * 1024, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4');
      expect(await _get(local, 'bytes=0-4194303'), Uint8List.sublistView(data, 0, 4194304)); // the usual speed
      await Future<void>.delayed(const Duration(milliseconds: 800)); // read-ahead done or dropped
      cdn.crawl = 2; // the next two requests: mpv's own chunk and the long one beside it
      final watch = Stopwatch()..start();
      const at = 11 * 512 * 1024;
      expect(await _get(local, 'bytes=$at-'), Uint8List.sublistView(data, at));
      // at ~0.3 MB/s the 4.7 MB would take ~15 s
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      expect(cdn.requests, greaterThan(4));
      expect(cdn.peak, lessThanOrEqualTo(2));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('a chunk left part done is not written twice by a request that runs through it', () async {
    // (the page's read of the index at the end is dropped half way to make room for
    // mpv, which then reads the index from just before it)
    const cs = 512 * 1024;
    final data = Uint8List.fromList(List.generate(24 * cs - 5000, (i) => (i * 31 + (i >> 11)) & 0xff));
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(chunkSize: cs, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final url = 'http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4';
      cdn.crawl = 2; // the page's two reads, the start and the end, come slowly
      proxy.prepare(url, tail: true);
      await Future<void>.delayed(const Duration(milliseconds: 350)); // the last chunk part done
      final local = await proxy.wrap(url);
      const at = 22 * cs + 1000;
      final got = await _get(local, 'bytes=$at-');
      expect(got.length, data.length - at);
      expect(got, Uint8List.sublistView(data, at));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('mpv waiting on a request that hangs gets its chunk on another connection', () async {
    final data = _file();
    final cdn = await _FakeCdn.start(data);
    final gw = await _gateway(cdn, [], size: data.length);
    final proxy = JavStreamProxy(chunkSize: 512 * 1024, userAgent: _ua, isCloud: (u) => u.port == cdn.server.port);
    try {
      final local = await proxy.wrap('http://127.0.0.1:${gw.port}/play/ol/115/cloud/x.mp4');
      expect(await _get(local, 'bytes=0-1048575'), Uint8List.sublistView(data, 0, 1048576));
      await Future<void>.delayed(const Duration(milliseconds: 800)); // read-ahead done or dropped
      cdn.hold = 1; // the seek's first request
      final watch = Stopwatch()..start();
      const at = 19 * 512 * 1024 + 1000;
      expect(await _get(local, 'bytes=$at-'), Uint8List.sublistView(data, at));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2500)));
      expect(cdn.peak, lessThanOrEqualTo(2));
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close();
    }
  });

  test('where an MP4 keeps its index', () {
    Uint8List box(String type, int size, {bool large = false}) {
      final b = BytesBuilder();
      if (large) {
        b.add([0, 0, 0, 1]);
        b.add(type.codeUnits);
        b.add([for (var i = 7; i >= 0; i--) (size >> (8 * i)) & 0xff]);
      } else {
        b.add([(size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff]);
        b.add(type.codeUnits);
      }
      return b.takeBytes();
    }

    Uint8List head(List<Uint8List> boxes, List<int> sizes) {
      final b = BytesBuilder();
      for (var i = 0; i < boxes.length; i++) {
        b.add(boxes[i]);
        if (i < boxes.length - 1) b.add(Uint8List(sizes[i] - boxes[i].length));
      }
      return b.takeBytes();
    }

    // ftyp (32) + free (8) + mdat (29 GB, 64-bit size) + moov at the end
    const mdat = 29456000000;
    final h = head([box('ftyp', 32), box('free', 8), box('mdat', mdat, large: true)], [32, 8]);
    expect(mp4IndexStart(h, 40 + mdat + 12000000), 40 + mdat);
    // index first ("fast start"): nothing at the end to fetch
    expect(mp4IndexStart(head([box('ftyp', 24), box('moov', 5000)], [24]), 1 << 30), isNull);
    // not an MP4
    expect(mp4IndexStart(Uint8List.fromList(List.filled(64, 0x47)), 1 << 30), isNull);
  });
}
