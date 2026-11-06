import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

const _subtitleExts = ['srt', 'ass', 'ssa', 'vtt'];

/// One hit of the Xunlei (迅雷) subtitle search.
class OnlineSubtitle {
  const OnlineSubtitle({required this.name, required this.url, required this.ext, this.extra = '', this.duration});

  final String name;

  /// Xunlei's links carry no extension; the format is in [ext].
  final String url;
  final String ext;
  final String extra;

  /// The length of the video the subtitle was made for: one close to this
  /// video's length is usually the right release.
  final Duration? duration;

  String get label => extra.isEmpty ? name : '$name ($extra)';

  /// Made for (about) this video: within 2 minutes of its length.
  bool fits(Duration video) => duration != null && video > Duration.zero && (duration! - video).abs() < const Duration(minutes: 2);
}

/// Subtitles in a Xunlei `oracle/subtitle` response that mpv can load.
List<OnlineSubtitle> parseXunleiSubtitles(Object? json) {
  if (json is! Map || json['code'] != 0 || json['data'] is! List) return const [];
  final out = <OnlineSubtitle>[];
  for (final item in json['data'] as List) {
    if (item is! Map) continue;
    final url = item['url'];
    if (url is! String || url.isEmpty) continue;
    final name = (item['name'] as String?)?.trim() ?? '';
    var ext = (item['ext'] as String?)?.trim().toLowerCase() ?? '';
    if (!_subtitleExts.contains(ext)) {
      final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
      ext = _subtitleExts.firstWhere(
        (e) => path.endsWith('.$e') || name.toLowerCase().endsWith('.$e'),
        orElse: () => '',
      );
    }
    if (ext.isEmpty) continue;
    final ms = int.tryParse('${item['duration'] ?? ''}');
    out.add(OnlineSubtitle(
      name: name.isEmpty ? url.split('/').last : name,
      url: url,
      ext: ext,
      extra: (item['extra_name'] as String?)?.trim() ?? '',
      duration: ms == null || ms <= 0 ? null : Duration(milliseconds: ms),
    ));
  }
  return out;
}

/// The player's helpers around mpv: subtitle look, online subtitles, the
/// hold-to-speed-up and skip keys, and a short on-screen message.
class JavPlayerTools extends ChangeNotifier {
  JavPlayerTools({required this.player, required this.code, http.Client? client}) : _client = client ?? http.Client();

  final Player player;

  /// 番号 of the playing movie ('' when it has none).
  final String code;
  final http.Client _client;

  JavPlayerSettings settings = JavPlayerSettings();

  /// Short status line shown over the video.
  final message = ValueNotifier<String?>(null);
  int _messageSerial = 0;

  StreamSubscription<Tracks>? _tracksSub;
  Timer? _reapplyTimer;
  bool _accelerating = false;
  double? _speedBeforeAcceleration;
  int _pendingSeekMs = 0;
  Timer? _seekTimer;
  Duration? _lastTarget;
  DateTime _lastSeekAt = DateTime(2000);
  bool _disposed = false;

  bool get accelerating => _accelerating;

  /// Subtitles shown (mpv `sub-visibility`).
  bool subtitlesOn = true;

  /// URLs of the online subtitles already loaded (to mark them in the list).
  final loadedOnline = <String>{};

  Future<void> init() async {
    settings = await JavPlayerSettings.load();
    if (_disposed) return;
    notifyListeners();
    // a newly opened file resets some subtitle properties: write ours again
    _tracksSub = player.stream.tracks.listen((_) {
      _reapplyTimer?.cancel();
      _reapplyTimer = Timer(const Duration(milliseconds: 600), () {
        if (!_disposed) unawaited(applySubtitleSettings());
      });
    });
    await applySubtitleSettings();
  }

  void toast(String text) {
    final serial = ++_messageSerial;
    message.value = text;
    Future<void>.delayed(const Duration(milliseconds: 2200), () {
      if (!_disposed && serial == _messageSerial) message.value = null;
    });
  }

  // ---------------- mpv ----------------

  NativePlayer? get native => player.platform is NativePlayer ? player.platform as NativePlayer : null;

  Future<void> setProperty(String property, String value) async {
    try {
      await native?.setProperty(property, value);
    } catch (_) {}
  }

  Future<String> getProperty(String property) async {
    try {
      return await native?.getProperty(property) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<bool> _command(List<String> args) async {
    final n = native;
    if (n == null) return false;
    try {
      await n.command(args);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Position, size, colour; after every file change (mpv resets some of them).
  Future<void> applySubtitleSettings() async {
    await setProperty('sub-pos', '${settings.mpvSubPos}');
    await setProperty('sub-font-size', settings.subtitleSize.round().toString());
    await setProperty('sub-color', settings.subtitleColor);
    await setProperty('sub-border-size', '2.5');
    await setProperty('sub-shadow-offset', '1');
    // ASS subtitles carry their own styles; keep them readable at our size
    await setProperty('sub-ass-override', 'force');
    await setProperty('sub-visibility', 'yes');
  }

  String? _sidBeforeOff;

  /// Off = no subtitle track (works with mpv drawing the subtitles and with
  /// Flutter drawing them, as on Android); on = the track that was showing.
  Future<void> setSubtitlesOn(bool on) async {
    if (!on) {
      final sid = await getProperty('sid');
      if (sid.isNotEmpty && sid != 'no') _sidBeforeOff = sid;
      await setProperty('sid', 'no');
    } else {
      await setProperty('sid', _sidBeforeOff ?? 'auto');
    }
    subtitlesOn = on;
    notifyListeners();
    toast(on ? '字幕已开启' : '字幕已关闭');
  }

  // ---------------- keys ----------------

  /// The hold-to-speed-up and skip keys (z / x / c by default). True when the
  /// event was one of them, so the player's own bindings don't also run.
  bool handleKey(KeyEvent event) {
    final label = event.logicalKey.keyLabel.toLowerCase();
    if (label.length != 1) return false;
    if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    if (label == settings.accelerateKey) {
      if (event is KeyDownEvent) unawaited(startAcceleration());
      if (event is KeyUpEvent) unawaited(stopAcceleration());
      return true;
    }
    final isForward = label == settings.forwardKey;
    final isBackward = label == settings.backwardKey;
    if (!isForward && !isBackward) return false;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      queueSeek(isForward ? settings.skipSeconds : -settings.skipSeconds);
    }
    return true;
  }

  Future<void> startAcceleration() async {
    if (_accelerating) return;
    _accelerating = true;
    _speedBeforeAcceleration = player.state.rate;
    notifyListeners();
    await player.setRate(settings.accelerationRate);
  }

  Future<void> stopAcceleration() async {
    if (!_accelerating) return;
    _accelerating = false;
    notifyListeners();
    await player.setRate(_speedBeforeAcceleration ?? 1.0);
    _speedBeforeAcceleration = null;
  }

  /// Quick repeated presses become one seek: 115 counts every connection a
  /// seek opens, so five taps must not be five requests.
  void queueSeek(double seconds) {
    _pendingSeekMs += (seconds * 1000).round();
    final total = _pendingSeekMs / 1000;
    toast('${total >= 0 ? '前进' : '后退'} ${total.abs().toStringAsFixed(total.abs() % 1 == 0 ? 0 : 1)} 秒');
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 400), () {
      final ms = _pendingSeekMs;
      _pendingSeekMs = 0;
      if (ms == 0 || _disposed) return;
      final duration = player.state.duration;
      // A 115 seek takes a moment: until it lands the position still reads the
      // old place, and the next jump must build on the last target instead.
      final now = DateTime.now();
      final pending = _lastTarget != null && now.difference(_lastSeekAt) < const Duration(seconds: 4) &&
          (player.state.position - _lastTarget!).abs() > const Duration(seconds: 2);
      var target = (pending ? _lastTarget! : player.state.position) + Duration(milliseconds: ms);
      if (target < Duration.zero) target = Duration.zero;
      if (duration > Duration.zero && target > duration) target = duration - const Duration(seconds: 1);
      _lastTarget = target;
      _lastSeekAt = now;
      unawaited(player.seek(target));
    });
  }

  // ---------------- subtitles ----------------

  Future<bool> addSubtitleFile(String path, String title) async {
    final ok = await _command(['sub-add', path, 'select', title, 'zh']);
    if (ok) {
      if (!subtitlesOn) {
        subtitlesOn = true;
        notifyListeners();
      }
      await applySubtitleSettings();
    }
    return ok;
  }

  Future<String> _tempFile(String name, List<int> bytes) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}javhub-subtitles');
    await dir.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}-$safe');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// A subtitle file of the library item (served by JavHub, behind the login).
  Future<void> loadRemoteFile(String name, String url, Map<String, String> headers) async {
    try {
      final r = await _client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return;
      await addSubtitleFile(await _tempFile(name, r.bodyBytes), name);
    } catch (_) {}
  }

  Future<List<OnlineSubtitle>> searchOnline() async {
    if (code.isEmpty) throw Exception('无法从片名识别番号');
    final uri = Uri.https('api-shoulei-ssl.xunlei.com', '/oracle/subtitle', {'name': code});
    final r = await _client
        .get(uri, headers: {'Accept': 'application/json, text/plain, */*', 'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 15));
    if (r.statusCode < 200 || r.statusCode >= 300) throw Exception('迅雷字幕接口返回 HTTP ${r.statusCode}');
    return parseXunleiSubtitles(jsonDecode(utf8.decode(r.bodyBytes)));
  }

  Future<bool> loadOnlineSubtitle(OnlineSubtitle sub) async {
    try {
      final r = await _client.get(Uri.parse(sub.url)).timeout(const Duration(seconds: 20));
      if (r.statusCode < 200 || r.statusCode >= 300 || r.bodyBytes.isEmpty) {
        toast('字幕下载失败 (HTTP ${r.statusCode})');
        return false;
      }
      // mpv detects the charset (GBK, UTF-16 ...) itself: the bytes are stored untouched
      final path = await _tempFile('${code.isEmpty ? 'subtitle' : code}.${sub.ext}', r.bodyBytes);
      final ok = await addSubtitleFile(path, '在线 · ${sub.name}');
      if (ok) {
        loadedOnline.add(sub.url);
        notifyListeners();
      }
      toast(ok ? '已加载字幕：${sub.name}' : '字幕加载失败');
      return ok;
    } on TimeoutException {
      toast('下载字幕超时');
    } catch (e) {
      toast('字幕加载失败: $e');
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _seekTimer?.cancel();
    _reapplyTimer?.cancel();
    unawaited(_tracksSub?.cancel());
    if (_accelerating) unawaited(player.setRate(_speedBeforeAcceleration ?? 1.0).catchError((_) {}));
    _client.close();
    message.dispose();
    super.dispose();
  }
}
