import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/player/stream_proxy.dart';

const _size = 10 * 1024 * 1024 + 12345;
const _ua = 'test-ua';

Uint8List _file() => Uint8List.fromList(List.generate(_size, (i) => (i * 31 + (i >> 11)) & 0xff));

/// A CDN with 115's rules: links bound to the User-Agent, and "pmt" 403 once
/// a file has more than 2 requests at the same time.
class _FakeCdn {
  _FakeCdn(this.server, this.data);

  final HttpServer server;
  final Uint8List data;
  int active = 0;
  int peak = 0;
  int requests = 0;
  int refusals = 0;
  int forcePmt = 0; // answer the next N requests with "pmt"
  bool expired = false;
  Duration delay = const Duration(milliseconds: 20);
  Duration? trickle; // a slow CDN: this long per 64 KiB

  static Future<_FakeCdn> start(Uint8List data) async {
    final cdn = _FakeCdn(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), data);
    cdn.server.listen(cdn._handle);
    return cdn;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/file.mp4?t=1');

  Future<void> _handle(HttpRequest req) async {
    requests++;
    final res = req.response;
    if (req.headers.value(HttpHeaders.userAgentHeader) != _ua || expired) {
      res.statusCode = 403;
      res.write('{"message":"expired"}');
      return res.close();
    }
    active++;
    peak = math.max(peak, active);
    try {
      if (active > 2 || forcePmt > 0) {
        if (forcePmt > 0) forcePmt--;
        refusals++;
        res.statusCode = 403;
        res.write('{"message":"115 pmt 3-2","status":403}');
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '')!;
      final start = int.parse(m[1]!);
      final end = m[2]!.isEmpty ? data.length - 1 : math.min(int.parse(m[2]!), data.length - 1);
      res.statusCode = 206;
      res.headers
        ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}')
        ..contentType = ContentType('video', 'mp4');
      res.contentLength = end - start + 1;
      await Future<void>.delayed(delay);
      final t = trickle;
      if (t == null) {
        res.add(Uint8List.sublistView(data, start, end + 1));
      } else {
        for (var p = start; p <= end; p += 65536) {
          res.add(Uint8List.sublistView(data, p, math.min(end + 1, p + 65536)));
          await res.flush();
          await Future<void>.delayed(t);
        }
      }
    } finally {
      active--;
      await res.close();
    }
  }
}

/// The Emby gateway: 302 to the CDN for the resolve request, plain bytes for a local item.
Future<HttpServer> _gateway(_FakeCdn cdn, List<Map<String, String?>> seen) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    seen.add({
      'path': req.uri.path,
      'resolve': req.headers.value(javResolveHeader),
      'token': req.headers.value('X-Emby-Token'),
      'ua': req.headers.value(HttpHeaders.userAgentHeader),
    });
    final res = req.response;
    if (req.uri.path.contains('/cloud')) {
      cdn.expired = false; // a fresh link
      res.statusCode = 302;
      res.headers.set(HttpHeaders.locationHeader, cdn.url.toString());
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

      // The signed link expired: the proxy asks the gateway for a new one.
      cdn.expired = true;
      final fresh = await _get(local, 'bytes=200-299');
      expect(fresh, Uint8List.sublistView(data, 200, 300));
      expect(seen.length, 2);
    } finally {
      await proxy.close();
      await gw.close(force: true);
      await cdn.server.close(force: true);
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
      await cdn.server.close(force: true);
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
      await cdn.server.close(force: true);
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
      await cdn.server.close(force: true);
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
      await cdn.server.close(force: true);
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
      await cdn.server.close(force: true);
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
