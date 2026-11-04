import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// The subtitle ball's brain: applies [JavPlayerSettings] to mpv and handles
/// the extra hotkeys (hold to speed up, forward / backward).
class JavPlayerTools extends ChangeNotifier {
  JavPlayerTools({required this.player, required this.code, http.Client? client}) : _client = client ?? http.Client();

  final Player player;

  /// 番号 of the playing movie ('' when it has none).
  final String code;
  final http.Client _client;

  JavPlayerSettings settings = JavPlayerSettings();

  /// Short status line for the ball's toast.
  final message = ValueNotifier<String?>(null);
  int _messageSerial = 0;

  final List<String> _addedSubtitles = [];
  StreamSubscription<Tracks>? _tracksSub;
  Timer? _reapplyTimer;
  bool _accelerating = false;
  double? _speedBeforeAcceleration;
  int _pendingSeekMs = 0;
  Timer? _seekTimer;
  bool _disposed = false;

  bool get accelerating => _accelerating;

  /// A text field in the ball's panel has focus: keys are typing, not hotkeys.
  bool panelFocused = false;

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
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!_disposed && serial == _messageSerial) message.value = null;
    });
  }

  // ---------------- mpv ----------------

  NativePlayer? get _native => player.platform is NativePlayer ? player.platform as NativePlayer : null;

  Future<void> _set(String property, String value) async {
    try {
      await _native?.setProperty(property, value);
    } catch (_) {}
  }

  Future<bool> _command(List<String> args) async {
    final native = _native;
    if (native == null) return false;
    try {
      await native.command(args);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Position, size, color and offset; after every change and whenever the
  /// track list changes.
  Future<void> applySubtitleSettings() async {
    await _set('sub-pos', '${settings.mpvSubPos}');
    await _set('sub-font-size', settings.subtitleSize.round().toString());
    await _set('sub-color', settings.subtitleColor);
    // ASS subtitles carry their own styles; let size / color / position apply
    await _set('sub-ass-override', 'force');
    await _set('sub-delay', settings.subtitleOffset.toStringAsFixed(2));
  }

  Future<void> updateSettings(void Function(JavPlayerSettings s) change) async {
    change(settings);
    notifyListeners();
    await applySubtitleSettings();
    unawaited(settings.save().catchError((_) {}));
  }

  Future<void> saveSettings() async {
    try {
      await settings.save();
      toast('设置已保存');
    } catch (e) {
      toast('保存设置失败: $e');
    }
  }

  // ---------------- hotkeys ----------------

  /// The accelerate / forward / backward keys. True when the event was one of
  /// them, so the player's own bindings don't also run.
  bool handleKey(KeyEvent event) {
    if (panelFocused) return false;
    final label = event.logicalKey.keyLabel.toLowerCase();
    if (label.length != 1) return false;
    if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    if (label == settings.accelerateKey) {
      if (event is KeyDownEvent) unawaited(_startAcceleration());
      if (event is KeyUpEvent) unawaited(_stopAcceleration());
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

  Future<void> _startAcceleration() async {
    if (_accelerating) return;
    _accelerating = true;
    _speedBeforeAcceleration = player.state.rate;
    notifyListeners();
    await player.setRate(settings.accelerationRate);
  }

  Future<void> _stopAcceleration() async {
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
    toast('${total >= 0 ? '快进' : '快退'} ${total.abs().toStringAsFixed(total.abs() % 1 == 0 ? 0 : 1)} 秒');
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 400), () {
      final ms = _pendingSeekMs;
      _pendingSeekMs = 0;
      if (ms == 0 || _disposed) return;
      final duration = player.state.duration;
      var target = player.state.position + Duration(milliseconds: ms);
      if (target < Duration.zero) target = Duration.zero;
      if (duration > Duration.zero && target > duration) target = duration - const Duration(seconds: 1);
      unawaited(player.seek(target));
    });
  }

  // ---------------- subtitles ----------------

  Future<bool> addSubtitleFile(String path, String title) async {
    final ok = await _command(['sub-add', path, 'select', title, 'zh']);
    if (ok) {
      _addedSubtitles.add(path);
      await applySubtitleSettings();
    }
    return ok;
  }

  Future<String> _tempFile(String name, List<int> bytes) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}javhub-subtitles');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}-$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// A subtitle file of the library item (served by JavHub, behind the login).
  Future<void> loadRemoteFile(String name, String url, Map<String, String> headers, {bool quiet = false}) async {
    try {
      final r = await _client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) throw Exception('HTTP ${r.statusCode}');
      final ok = await addSubtitleFile(await _tempFile(name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'), r.bodyBytes), name);
      if (!quiet) toast(ok ? '字幕已加载: $name' : '字幕加载失败');
    } catch (e) {
      if (!quiet) toast('字幕加载失败: $e');
    }
  }

  Future<void> loadLocalSubtitle() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: _subtitleExts, dialogTitle: '选择字幕文件');
      final file = result?.files.single;
      final path = file?.path;
      if (path == null) return;
      final ok = await addSubtitleFile(path, '本地: ${file!.name}');
      toast(ok ? '本地字幕加载成功' : '本地字幕加载失败');
    } catch (e) {
      toast('本地字幕加载失败: $e');
    }
  }

  Future<List<OnlineSubtitle>> searchOnline() async {
    if (code.isEmpty) {
      toast('无法从片名识别番号');
      return const [];
    }
    toast('正在搜索字幕: $code …');
    try {
      final uri = Uri.https('api-shoulei-ssl.xunlei.com', '/oracle/subtitle', {'name': code});
      final r = await _client
          .get(uri, headers: {'Accept': 'application/json, text/plain, */*', 'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        toast('字幕搜索出错: 服务器错误 ${r.statusCode}');
        return const [];
      }
      final subs = parseXunleiSubtitles(jsonDecode(utf8.decode(r.bodyBytes)));
      toast(subs.isEmpty ? '没有找到 $code 的字幕' : '找到 ${subs.length} 个字幕');
      return subs;
    } on TimeoutException {
      toast('字幕搜索超时 (15 秒)');
    } catch (e) {
      toast('字幕搜索出错: $e');
    }
    return const [];
  }

  Future<void> loadOnlineSubtitle(OnlineSubtitle sub) async {
    toast('正在加载在线字幕…');
    try {
      final r = await _client.get(Uri.parse(sub.url)).timeout(const Duration(seconds: 20));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        toast('下载失败 (HTTP ${r.statusCode})');
        return;
      }
      if (r.bodyBytes.isEmpty) {
        toast('字幕内容为空');
        return;
      }
      // mpv detects the charset (GBK, UTF-16 ...) itself: the bytes are stored untouched
      final path = await _tempFile('${code.isEmpty ? 'subtitle' : code}.${sub.ext}', r.bodyBytes);
      final ok = await addSubtitleFile(path, '在线: ${sub.name}');
      toast(ok ? '在线字幕加载成功' : '在线字幕加载失败');
    } on TimeoutException {
      toast('下载字幕超时 (20 秒)');
    } catch (e) {
      toast('在线字幕加载失败: $e');
    }
  }

  Future<void> openSubtitlecat() async {
    if (code.isEmpty) {
      toast('无法从片名识别番号');
      return;
    }
    final ok = await launchUrl(Uri.https('www.subtitlecat.com', '/index.php', {'search': code}), mode: LaunchMode.externalApplication);
    toast(ok ? '已在浏览器打开 Subtitlecat: $code' : '无法打开浏览器');
  }

  /// Removes the subtitles loaded from the ball (local or online).
  Future<void> clearSubtitles() async {
    final native = _native;
    if (native == null || _addedSubtitles.isEmpty) {
      toast('没有可清除的外挂字幕');
      return;
    }
    try {
      final tracks = jsonDecode(await native.getProperty('track-list'));
      if (tracks is List) {
        for (final t in tracks) {
          if (t is Map && t['type'] == 'sub' && _addedSubtitles.contains(t['external-filename'])) {
            await _command(['sub-remove', '${t['id']}']);
          }
        }
      }
    } catch (_) {}
    _addedSubtitles.clear();
    toast('字幕已清除');
  }

  @override
  void dispose() {
    _disposed = true;
    _seekTimer?.cancel();
    _reapplyTimer?.cancel();
    unawaited(_tracksSub?.cancel());
    _client.close();
    message.dispose();
    super.dispose();
  }
}
