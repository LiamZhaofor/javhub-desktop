import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../models.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart' show ImageStore;
import 'stream_proxy.dart';
import 'touch_controls.dart';
import 'tools.dart';

class PlaySource {
  const PlaySource({required this.url, required this.cloud, this.local = false});

  final String url;

  /// A 115 file: played through the loopback proxy straight from the CDN.
  final bool cloud;

  /// [url] already is the loopback proxy's (the main window's, for a player window).
  final bool local;
}

/// Where a movie was left: JavHub's shared progress (any device, Emby included),
/// else this device's own note of it (offline). (0, '') = from the start.
Future<(int, String)> resumePosition({required String itemId, required int part, required String url, bool resume = true}) async {
  if (!resume) return (0, '');
  if (itemId.isNotEmpty) {
    Progress? remote;
    var asked = false;
    try {
      remote = (await App.api.progress(itemId).timeout(const Duration(seconds: 6)))[part];
      asked = true;
    } catch (_) {}
    if (asked) {
      if (remote == null || !remote.resumable) return (0, '');
      final pos = remote.pos.floor();
      if (pos < 30 || (remote.dur > 0 && pos > remote.dur - 60)) return (0, '');
      return (pos, remote.device);
    }
  }
  final saved = (await SharedPreferences.getInstance()).getInt(positionKey(url)) ?? 0;
  return saved >= 30 ? (saved, '') : (0, '');
}

/// This device's own note of where [url] was left.
String positionKey(String url) => 'pos.${url.split('?').first}';

enum _Panel { subtitles, speed, settings }

const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

/// The steps 快进 / 快退 can take.
const seekSteps = [5.0, 10.0, 15.0, 30.0, 60.0];

String _secs(double s) => s.toStringAsFixed(s % 1 == 0 ? 0 : 1);

IconData _stepIcon(double s, {required bool back}) => switch (s) {
  5 => back ? Icons.replay_5_rounded : Icons.forward_5_rounded,
  10 => back ? Icons.replay_10_rounded : Icons.forward_10_rounded,
  30 => back ? Icons.replay_30_rounded : Icons.forward_30_rounded,
  _ => back ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
};
const _fits = {BoxFit.contain: '适应', BoxFit.cover: '填充', BoxFit.fill: '拉伸'};

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.title,
    required this.code,
    required this.source,
    this.itemId = '',
    this.part = 0,
    this.resume = true,
    this.subtitles = const [],
    this.startAt,
    this.windowed = false,
  });

  /// Where to start, already worked out (seconds, device); null: look it up.
  final (int, String)? startAt;

  /// The only thing in a window of its own: back / Esc closes the window.
  final bool windowed;

  final String title;
  final String code;

  /// The library item (for its seek-bar previews and the shared progress).
  final String itemId;

  /// Which of the item's videos (cd1, cd2 ...).
  final int part;

  /// Continue where it was left (on any device); false: from the start.
  final bool resume;
  final PlaySource source;

  /// (name, url) of the subtitle files next to the video in the library.
  final List<(String, String)> subtitles;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      title: widget.title,
      // desktop: mpv draws the subtitles itself (ASS styles kept); Android: Flutter
      // draws them (libass there has no CJK font: Chinese would be boxes)
      libass: isDesktop,
      bufferSize: 64 << 20,
    ),
  );
  late final VideoController _video = VideoController(_player);
  late final JavPlayerTools _tools = JavPlayerTools(player: _player, code: widget.code);

  String? _status = '正在打开…';
  String? _error;
  final _subs = <StreamSubscription<Object?>>[];
  Duration _lastPos = Duration.zero;
  Duration _savedAt = Duration.zero;
  bool _resumeDone = false; // no saving before the old position was read

  final _panel = ValueNotifier<_Panel?>(null);
  final _fit = ValueNotifier<BoxFit>(BoxFit.contain);
  final _hwdec = ValueNotifier<bool>(true);
  final _stats = ValueNotifier<bool>(false);
  final _statsText = ValueNotifier<String>('');
  Timer? _statsTimer;

  // seek-bar previews
  Trickplay? _tp;
  ui.Image? _sprite;
  final _hoverX = ValueNotifier<double?>(null);

  /// Phone: where the seek bar is being dragged (0-1), for the preview bubble.
  final _dragF = ValueNotifier<double?>(null);
  Timer? _hoverIdle;

  // online subtitle search
  List<OnlineSubtitle>? _online;
  bool _searching = false;
  String? _searchError;

  String get _posKey => positionKey(widget.source.url);

  // → held down: speed up like the accelerate key; tapped: forward 10 s
  Timer? _rightHold;
  bool _rightAccelerating = false;

  @override
  void initState() {
    super.initState();
    if (widget.windowed) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    unawaited(_start());
    if (widget.itemId.isNotEmpty) unawaited(_loadPreviews());
    if (!isDesktop) {
      // a phone plays fullscreen, sideways
      unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]));
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
  }

  /// The sprite sheet behind the seek-bar previews. JavHub makes it on the first
  /// request (about a minute for a 115 movie), so this keeps asking for a while.
  Future<void> _loadPreviews() async {
    for (var i = 0; i < 40 && mounted; i++) {
      try {
        final tp = await App.api.trickplay(widget.itemId);
        if (tp.ready) {
          final bytes = await ImageStore.instance.load(App.api.url(tp.sprite), App.api.authHeaders);
          if (bytes == null) return;
          final image = await decodeImageFromList(bytes);
          if (!mounted) {
            image.dispose();
            return;
          }
          setState(() {
            _tp = tp;
            _sprite = image;
          });
          return;
        }
        if (tp.status == 'failed') return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 15));
    }
  }

  Future<void> _start() async {
    await _tools.setProperty('network-timeout', '20');
    await _tools.setProperty('demuxer-max-bytes', '256MiB');
    await _tools.setProperty('demuxer-max-back-bytes', '64MiB');
    // after a seek (or a stall) play on once 0.6 s is buffered, not mpv's 1 s
    await _tools.setProperty('cache-pause-wait', '0.6');
    await _tools.setProperty('stream-lavf-o', 'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_streamed=1,reconnect_delay_max=5');
    await _tools.setProperty('sub-auto', 'no');
    if (isDesktop) {
      await _tools.setProperty('sub-font', Platform.isLinux ? 'Noto Sans CJK SC' : 'Microsoft YaHei');
      await _tools.setProperty('hwdec', 'auto-safe');
    }

    _subs.add(_player.stream.error.listen((e) {
      if (mounted) _tools.toast('播放出错: $e');
    }));
    _subs.add(_player.stream.position.listen((p) {
      _lastPos = p;
      if (_resumeDone && (p - _savedAt).abs() > const Duration(seconds: 15)) {
        _savedAt = p;
        unawaited(_savePosition());
      }
    }));
    var moved = false;
    _subs.add(_player.stream.position.listen((p) {
      if (!moved && p > Duration.zero) {
        moved = true;
        trace('position ${p.inMilliseconds} ms');
      }
    }));
    _subs.add(_player.stream.buffering.listen((b) => trace('buffering $b')));
    _subs.add(_player.stream.playing.listen((playing) {
      trace('playing $playing');
      if (playing && _status != null && mounted) setState(() => _status = null);
      if (!playing && _resumeDone) unawaited(_savePosition());
    }));

    // where to start, asked while the stream is being set up: mpv then opens right
    // there instead of playing from 0:00 and seeking (one CDN round trip less)
    trace('play pressed');
    final startAt = widget.startAt != null
        ? Future.value(widget.startAt!)
        : resumePosition(itemId: widget.itemId, part: widget.part, url: widget.source.url, resume: widget.resume);
    var url = widget.source.url;
    var headers = widget.source.local ? const <String, String>{} : App.api.authHeaders;
    if (widget.source.cloud && !widget.source.local) {
      setState(() => _status = '正在连接 115…');
      final local = await JavStreamProxy.instance.wrap(url, headers: App.api.authHeaders);
      if (local != url) {
        url = local;
        headers = const {}; // loopback: no login needed
      }
    }
    final (start, from) = await startAt;
    trace('start position $start');
    if (!mounted) return;
    setState(() => _status = '正在缓冲…');
    try {
      await _player.open(Media(url, httpHeaders: headers, start: start > 0 ? Duration(seconds: start) : null));
      trace('opened');
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开视频: $e');
      return;
    }
    await _tools.init();
    if (start > 0) _tools.toast('从上次的 ${fmtClock(Duration(seconds: start))} 继续${from.isEmpty || from == _device ? '' : '（$from）'}');
    _resumeDone = true;
    // the library's own subtitles: the first one ends up selected
    for (final (name, subUrl) in widget.subtitles.reversed) {
      await _tools.loadRemoteFile(name, subUrl, App.api.authHeaders);
    }
    if (_tools.settings.autoSubtitle && widget.subtitles.isEmpty) unawaited(_autoSubtitle());
  }

  /// 设置 → 自动加载在线字幕: a movie without subtitles of its own gets the first
  /// online one (the ones made for a video of this length come first).
  Future<void> _autoSubtitle() async {
    if (widget.code.isEmpty) return;
    // the length decides which come first: wait for it (a moment after opening)
    for (var i = 0; i < 40 && mounted && _player.state.duration <= Duration.zero; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // the file has subtitles inside it: those are shown, nothing to fetch
    final inside = _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no');
    if (!mounted || inside.isNotEmpty) return;
    await _searchOnline();
    final found = _online;
    if (!mounted || found == null) return;
    if (found.isEmpty) {
      _tools.toast('没有找到 ${widget.code} 的在线字幕');
      return;
    }
    await _tools.loadOnlineSubtitle(found.first);
    if (mounted) setState(() {});
  }

  // ---------------- its own window ----------------

  @override
  void onWindowClose() => unawaited(_closeWindow());

  bool _closing = false;

  /// Gone at once: the window hides, the position is saved (a moment at most), and the
  /// process ends - tearing the engine and mpv down in order took seconds (a stream
  /// waiting on the network) and on Linux crashed the engine.
  Future<void> _closeWindow() async {
    if (_closing) return;
    _closing = true;
    unawaited(windowManager.hide());
    unawaited(_player.pause().catchError((_) {}));
    if (_resumeDone) await _savePosition().timeout(const Duration(milliseconds: 1500), onTimeout: () {});
    exit(0);
  }

  static String get _device => platformName;

  /// Where to resume next time (also saved during playback: closing the window
  /// skips dispose()).
  Future<void> _savePosition() async {
    final pos = _lastPos.inSeconds;
    final duration = _player.state.duration.inSeconds;
    // (a player window leaves the settings file to the main window: two processes
    // writing it would undo each other's changes; JavHub keeps the position)
    if (!widget.windowed) {
      final p = await SharedPreferences.getInstance();
      // finished (or barely started): next time from the start
      if (pos > 30 && (duration == 0 || pos < duration - 60)) {
        await p.setInt(_posKey, pos);
      } else {
        await p.remove(_posKey);
      }
    }
    // the shared progress: the other devices (and the home page) go on from here
    if (widget.itemId.isNotEmpty && duration > 0 && pos > 0) {
      try {
        await App.api.saveProgress(widget.itemId, widget.part, pos.toDouble(), duration.toDouble(), _device);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    if (_resumeDone) unawaited(_savePosition());
    if (widget.windowed) windowManager.removeListener(this);
    _rightHold?.cancel();
    _statsTimer?.cancel();
    _hoverIdle?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _tools.dispose();
    unawaited(_player.dispose());
    for (final n in [_panel, _fit, _hwdec, _stats, _statsText, _hoverX, _dragF]) {
      n.dispose();
    }
    if (!isDesktop) {
      unawaited(SystemChrome.setPreferredOrientations(const []));
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _sprite?.dispose();
    super.dispose();
  }

  // ---------------- actions ----------------

  void _back(BuildContext context) {
    if (_panel.value != null) {
      _panel.value = null;
    } else if (isFullscreen(context)) {
      unawaited(exitFullscreen(context));
    } else if (widget.windowed) {
      unawaited(_closeWindow());
    } else {
      Navigator.of(this.context).maybePop();
    }
  }

  void _toggle(_Panel p) => _panel.value = _panel.value == p ? null : p;

  void _volume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    unawaited(_player.setVolume(v));
    _tools.toast('音量 ${v.round()}');
  }

  Future<void> _searchOnline() async {
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final found = await _tools.searchOnline();
      final video = _player.state.duration;
      // the ones made for a video of this length first
      found.sort((a, b) => (b.fits(video) ? 1 : 0) - (a.fits(video) ? 1 : 0));
      if (mounted) setState(() => _online = found);
    } catch (e) {
      if (mounted) setState(() => _searchError = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _screenshot() async {
    try {
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (bytes == null) throw Exception('没有画面');
      final pictures = await picturesDir();
      final dir = Directory('${pictures.path}${Platform.pathSeparator}JavHub');
      await dir.create(recursive: true);
      final t = _player.state.position;
      final name = '${widget.code.isEmpty ? 'JavHub' : widget.code}_${fmtClock(t).replaceAll(':', '-')}.jpg';
      await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(bytes);
      _tools.toast('截图已保存到 ${dir.path}${Platform.pathSeparator}$name');
    } catch (e) {
      _tools.toast('截图失败: $e');
    }
  }

  void _setStats(bool on) {
    _stats.value = on;
    _statsTimer?.cancel();
    if (!on) return;
    Future<void> poll() async {
      final g = _tools.getProperty;
      final values = await Future.wait([
        g('video-codec'), g('hwdec-current'), g('estimated-vf-fps'), g('video-bitrate'),
        g('audio-codec-name'), g('demuxer-cache-duration'), g('frame-drop-count'), g('cache-speed'),
      ]);
      final s = _player.state;
      String num(String v, [int digits = 1]) => double.tryParse(v)?.toStringAsFixed(digits) ?? '-';
      final kbps = (double.tryParse(values[3]) ?? 0) / 1000;
      final speed = (double.tryParse(values[7]) ?? 0) / 1024 / 1024;
      _statsText.value = [
        '分辨率  ${s.width ?? '-'} × ${s.height ?? '-'}   ${num(values[2], 2)} fps',
        '视频    ${values[0].isEmpty ? '-' : values[0]}',
        '解码    ${values[1].isEmpty || values[1] == 'no' ? '软件' : '硬件 (${values[1]})'}',
        '码率    ${kbps > 0 ? '${kbps.toStringAsFixed(0)} kbps' : '-'}',
        '音频    ${values[4].isEmpty ? '-' : values[4]}',
        '缓冲    ${num(values[5])} 秒   下载 ${speed.toStringAsFixed(2)} MB/s',
        '丢帧    ${values[6].isEmpty ? '0' : values[6]}',
        '来源    ${widget.source.cloud ? '115 直连（本地代理）' : 'NAS'}',
      ].join('\n');
    }

    unawaited(poll());
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(poll()));
  }

  // ---------------- keys ----------------

  // Every player key is handled here, on a node above everything in the player:
  // media_kit's own shortcuts only fire while its inner node has the focus, which
  // it loses to ours, to a menu row, ... (arrow keys then did nothing).
  KeyEventResult _onKey(BuildContext context, KeyEvent e) {
    if (_tools.handleKey(e)) return KeyEventResult.handled;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      // tapped: forward 10 s (on release); held: the accelerate key's speed-up
      if (e is KeyDownEvent) {
        _rightHold?.cancel();
        _rightAccelerating = false;
        _rightHold = Timer(const Duration(milliseconds: 350), () {
          _rightAccelerating = true;
          unawaited(_tools.startAcceleration());
        });
      } else if (e is KeyUpEvent) {
        final held = _rightHold != null;
        _rightHold?.cancel();
        _rightHold = null;
        if (_rightAccelerating) {
          unawaited(_tools.stopAcceleration());
        } else if (held) {
          _tools.queueSeek(_tools.settings.seekStep);
        }
        _rightAccelerating = false;
      }
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _tools.queueSeek(-_tools.settings.seekStep);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        _volume(key == LogicalKeyboardKey.arrowUp ? 5 : -5);
        return KeyEventResult.handled;
      }
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_player.playOrPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.enter) {
      unawaited(toggleFullscreen(context));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _back(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------- controls ----------------

  // The context of the controls themselves (not state.context, which stays the
  // non-fullscreen Video's): isFullscreen / exitFullscreen need the route they are in.
  Widget _controls(VideoState state) => Builder(builder: (context) => _overlay(state, context));

  Widget _overlay(VideoState state, BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(context, e),
      child: Stack(
        children: [
          if (!isDesktop)
            TouchControls(
              player: _player,
              tools: _tools,
              topBar: _touchTop(),
              bottomBar: _touchBottom(),
              drag: _dragF,
              panelOpen: _panel,
            )
          else
            MaterialDesktopVideoControls(state),
          if (!isDesktop) _dragPreview(),
          if (isDesktop) ...[
          // seek-bar previews: a strip over media_kit's seek bar (16 px side margins,
          // 36 px high, 16 px into the 64 px button bar) that only listens to hovering,
          // so dragging and clicking still reach the bar underneath
          Positioned(
            left: 16,
            right: 16,
            bottom: 48,
            height: 36,
            child: MouseRegion(
              opaque: false,
              hitTestBehavior: HitTestBehavior.translucent,
              onHover: (e) {
                _hoverX.value = e.localPosition.dx;
                // the controls fade out after ~3 s without movement: so does the preview
                _hoverIdle?.cancel();
                _hoverIdle = Timer(const Duration(milliseconds: 2800), () => _hoverX.value = null);
              },
              onExit: (_) {
                _hoverIdle?.cancel();
                _hoverX.value = null;
              },
              child: const SizedBox.expand(),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, c) => ValueListenableBuilder<double?>(
                  valueListenable: _hoverX,
                  builder: (_, x, _) {
                    final duration = _player.state.duration;
                    final barW = c.maxWidth - 32;
                    if (x == null || duration <= Duration.zero || barW <= 0) return const SizedBox.shrink();
                    final f = (x / barW).clamp(0.0, 1.0);
                    final t = duration.inMilliseconds * f / 1000;
                    final tp = _tp, sprite = _sprite;
                    final w = tp != null && sprite != null ? 208.0 : 72.0;
                    final h = tp != null && sprite != null ? 208.0 * tp.h / tp.w : 0.0;
                    final left = (16 + x - w / 2).clamp(8.0, c.maxWidth - w - 8);
                    return Stack(children: [
                      Positioned(
                        left: left,
                        bottom: 92,
                        child: _PreviewBubble(
                          width: w,
                          height: h,
                          label: fmtClock(Duration(milliseconds: (t * 1000).round())),
                          sprite: sprite,
                          tp: tp,
                          seconds: t,
                        ),
                      ),
                    ]);
                  },
                ),
              ),
            ),
          ),
          ],
          // statistics, top left
          ValueListenableBuilder<bool>(
            valueListenable: _stats,
            builder: (_, on, _) => !on
                ? const SizedBox.shrink()
                : Positioned(
                    left: 16,
                    top: 64,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: const Color(0xB0000000), borderRadius: BorderRadius.circular(10)),
                        child: ValueListenableBuilder<String>(
                          valueListenable: _statsText,
                          builder: (_, t, _) => Text(t, style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.6, fontFamily: 'Consolas')),
                        ),
                      ),
                    ),
                  ),
          ),
          // messages and the speed-up pill, top centre
          Positioned(
            top: 64,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_tools, _tools.message]),
                  builder: (_, _) {
                    final text = _tools.accelerating
                        ? '▶▶  ${_tools.settings.accelerationRate.toStringAsFixed(_tools.settings.accelerationRate % 1 == 0 ? 0 : 1)}× 加速中'
                        : _tools.message.value;
                    return AnimatedOpacity(
                      opacity: text == null ? 0 : 1,
                      duration: const Duration(milliseconds: 180),
                      child: text == null ? const SizedBox.shrink() : _Pill(text),
                    );
                  },
                ),
              ),
            ),
          ),
          if (_status != null || _error != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                  decoration: BoxDecoration(color: const Color(0xC0000000), borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_error == null) ...[
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      const SizedBox(width: 12),
                    ],
                    Text(_error ?? _status!, style: TextStyle(color: _error == null ? Colors.white : const Color(0xFFFF8A8D), fontSize: 14)),
                  ]),
                ),
              ),
            ),
          // the open menu, above the button bar on the right
          ValueListenableBuilder<_Panel?>(
            valueListenable: _panel,
            builder: (context, panel, _) => panel == null
                ? const SizedBox.shrink()
                : Stack(children: [
                    // a click anywhere else closes it
                    Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _panel.value = null)),
                    Positioned(
                      right: 16,
                      bottom: 76,
                      child: _PanelBox(
                        child: switch (panel) {
                          _Panel.subtitles => _subtitlePanel(),
                          _Panel.speed => _speedPanel(),
                          _Panel.settings => _settingsPanel(state),
                        },
                      ),
                    ),
                  ]),
          ),
        ],
      ),
    );
  }

  Widget _subtitlePanel() => StatefulBuilder(
    builder: (context, setLocal) {
      void refresh(VoidCallback f) {
        f();
        setLocal(() {});
      }

      return AnimatedBuilder(
        animation: _tools,
        builder: (_, _) => StreamBuilder<Tracks>(
          // the list grows when a subtitle is added; the selection changes on its own
          stream: _player.stream.tracks,
          builder: (_, _) => StreamBuilder<Track>(
          stream: _player.stream.track,
          builder: (_, _) {
            final tracks = _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
            final video = _player.state.duration;
            // mpv's own idea of the selected track: a sub-add selects without media_kit noticing
            return FutureBuilder<String>(
              future: _tools.getProperty('sid'),
              builder: (_, sid) => SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PanelTitle('字幕', trailing: Switch(value: _tools.subtitlesOn, onChanged: (v) => _tools.setSubtitlesOn(v))),
                  if (tracks.isNotEmpty) ...[
                    const _PanelLabel('字幕轨'),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 150),
                      child: ListView(shrinkWrap: true, children: [
                        for (final t in tracks)
                          _MenuRow(
                            selected: t.id == sid.data && _tools.subtitlesOn,
                            title: t.title ?? t.language ?? '字幕 ${t.id}',
                            onTap: () async {
                              await _player.setSubtitleTrack(t);
                              if (!_tools.subtitlesOn) await _tools.setSubtitlesOn(true);
                              setLocal(() {});
                            },
                          ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _PanelLabel('在线字幕${widget.code.isEmpty ? '' : ' · ${widget.code}'}',
                      trailing: _online == null
                          ? null
                          : InkWell(
                              onTap: _searching ? null : () => _searchOnline().then((_) => setLocal(() {})),
                              child: const Icon(Icons.refresh_rounded, size: 16, color: Colors.white54),
                            )),
                  if (_online == null && !_searching)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: FilledButton.icon(
                        onPressed: widget.code.isEmpty ? null : () => _searchOnline().then((_) => setLocal(() {})),
                        icon: const Icon(Icons.travel_explore_rounded, size: 18),
                        label: const Text('按番号搜索字幕'),
                      ),
                    ),
                  if (_searching)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    ),
                  if (_searchError != null)
                    Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 10), child: Text(_searchError!, style: const TextStyle(color: Color(0xFFFF8A8D), fontSize: 12.5))),
                  if (_online != null && !_searching)
                    _online!.isEmpty
                        ? const Padding(padding: EdgeInsets.fromLTRB(14, 4, 14, 12), child: Text('没有找到在线字幕', style: TextStyle(color: Colors.white54, fontSize: 12.5)))
                        : ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 260),
                            child: ListView(shrinkWrap: true, children: [
                              for (final s in _online!)
                                _MenuRow(
                                  selected: _tools.loadedOnline.contains(s.url),
                                  title: s.name,
                                  subtitle: [s.ext.toUpperCase(), if (s.duration != null) fmtClock(s.duration!), if (s.extra.isNotEmpty) s.extra].join(' · '),
                                  tag: s.fits(video) ? '推荐' : null,
                                  onTap: () => _tools.loadOnlineSubtitle(s).then((_) => refresh(() {})),
                                ),
                            ]),
                          ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
            );
          },
        ),
        ),
      );
    },
  );

  Widget _speedPanel() => StreamBuilder<double>(
    stream: _player.stream.rate,
    builder: (_, _) => SizedBox(
      width: 200,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _PanelTitle('播放速度'),
        for (final r in _rates)
          _MenuRow(
            selected: (r - _player.state.rate).abs() < 0.01,
            title: r == 1.0 ? '正常' : '${r}x',
            onTap: () {
              unawaited(_player.setRate(r));
              _panel.value = null;
            },
          ),
        const SizedBox(height: 6),
      ]),
    ),
  );

  Widget _settingsPanel(VideoState state) => StreamBuilder<Track>(
    stream: _player.stream.track,
    builder: (_, _) {
      final audio = _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
      return SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _PanelTitle('播放设置'),
          const _PanelLabel('画面比例'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ValueListenableBuilder<BoxFit>(
              valueListenable: _fit,
              builder: (_, fit, _) => Row(children: [
                for (final e in _fits.entries)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _Segment(
                        text: e.value,
                        selected: fit == e.key,
                        onTap: () {
                          _fit.value = e.key;
                          state.update(fit: e.key);
                        },
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const _PanelLabel('快进 / 快退'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: AnimatedBuilder(
              animation: _tools,
              builder: (_, _) => Row(children: [
                for (final s in seekSteps)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _Segment(
                        text: '${_secs(s)}秒',
                        selected: _tools.settings.seekStep == s,
                        onTap: () => unawaited(_tools.setSeekStep(s)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          if (audio.length > 1) ...[
            const _PanelLabel('音轨'),
            for (final t in audio)
              _MenuRow(
                selected: t.id == _player.state.track.audio.id,
                title: [t.title, t.language].whereType<String>().join(' · ').ifEmpty('音轨 ${t.id}'),
                onTap: () => unawaited(_player.setAudioTrack(t)),
              ),
          ],
          const SizedBox(height: 4),
          if (isDesktop) ValueListenableBuilder<bool>(
            valueListenable: _hwdec,
            builder: (_, on, _) => _SwitchRow(
              icon: Icons.memory_rounded,
              title: '硬件解码',
              value: on,
              onChanged: (v) {
                _hwdec.value = v;
                unawaited(_tools.setProperty('hwdec', v ? 'auto-safe' : 'no'));
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _stats,
            builder: (_, on, _) => _SwitchRow(icon: Icons.analytics_outlined, title: '统计信息', value: on, onChanged: _setStats),
          ),
          if (isDesktop) _MenuRow(
            icon: Icons.photo_camera_outlined,
            title: '截图',
            subtitle: Platform.isLinux ? '保存到 图片/JavHub' : '保存到 图片\\JavHub',
            onTap: () {
              _panel.value = null;
              unawaited(_screenshot());
            },
          ),
          const SizedBox(height: 6),
        ]),
      );
    },
  );

  MaterialDesktopVideoControlsThemeData _theme() => MaterialDesktopVideoControlsThemeData(
    seekBarThumbColor: accent,
    seekBarPositionColor: accent,
    seekBarThumbSize: 14,
    seekBarHeight: 4,
    seekBarHoverHeight: 6,
    volumeBarActiveColor: accent,
    volumeBarThumbColor: accent,
    buttonBarHeight: 64,
    buttonBarButtonSize: 26,
    toggleFullscreenOnDoublePress: true,
    // all keys go through _onKey (an empty map turns media_kit's own off)
    keyboardShortcuts: const {},
    topButtonBar: [
      Builder(builder: (context) => MaterialDesktopCustomButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => _back(context))),
      const SizedBox(width: 8),
      Expanded(
        child: Text(widget.title, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      if (widget.source.cloud)
        Container(
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFF2563EB), borderRadius: BorderRadius.circular(5)),
          child: const Text('115', style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ),
    ],
    bottomButtonBar: [
      const MaterialDesktopPlayOrPauseButton(),
      AnimatedBuilder(
        animation: _tools,
        builder: (_, _) {
          final s = _tools.settings.seekStep;
          return _BarButton(icon: _stepIcon(s, back: true), tooltip: '后退 ${_secs(s)} 秒 (←)', onPressed: () => _tools.queueSeek(-s));
        },
      ),
      AnimatedBuilder(
        animation: _tools,
        builder: (_, _) {
          final s = _tools.settings.seekStep;
          return _BarButton(icon: _stepIcon(s, back: false), tooltip: '前进 ${_secs(s)} 秒 (→，按住加速)', onPressed: () => _tools.queueSeek(s));
        },
      ),
      const MaterialDesktopVolumeButton(),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      AnimatedBuilder(
        animation: _tools,
        builder: (_, _) => _BarButton(
          icon: _tools.subtitlesOn ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined,
          tooltip: '字幕',
          active: _panel.value == _Panel.subtitles,
          onPressed: () => _toggle(_Panel.subtitles),
        ),
      ),
      StreamBuilder<double>(
        stream: _player.stream.rate,
        builder: (_, _) => _BarTextButton(
          text: _player.state.rate == 1.0 ? '倍速' : '${_player.state.rate}x',
          tooltip: '播放速度',
          onPressed: () => _toggle(_Panel.speed),
        ),
      ),
      _BarButton(icon: Icons.settings_rounded, tooltip: '播放设置', onPressed: () => _toggle(_Panel.settings)),
      const MaterialDesktopFullscreenButton(),
    ],
  );

  /// The preview bubble while the phone's seek bar is dragged.
  Widget _dragPreview() => Positioned.fill(
    child: IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) => ValueListenableBuilder<double?>(
          valueListenable: _dragF,
          builder: (_, f, _) {
            final duration = _player.state.duration;
            if (f == null || duration <= Duration.zero) return const SizedBox.shrink();
            final t = duration.inMilliseconds * f / 1000;
            final tp = _tp, sprite = _sprite;
            final w = tp != null && sprite != null ? 200.0 : 80.0;
            final h = tp != null && sprite != null ? 200.0 * tp.h / tp.w : 0.0;
            final x = 16 + f * (c.maxWidth - 32);
            return Stack(children: [
              Positioned(
                left: (x - w / 2).clamp(8.0, c.maxWidth - w - 8),
                bottom: 78,
                child: _PreviewBubble(width: w, height: h, label: fmtClock(Duration(milliseconds: (t * 1000).round())), sprite: sprite, tp: tp, seconds: t),
              ),
            ]);
          },
        ),
      ),
    ),
  );

  // The phone's bars (TouchControls draws them, and owns the gestures).
  List<Widget> _touchTop() => [
      IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
      const SizedBox(width: 4),
      Expanded(
        child: Text(widget.title, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      if (widget.source.cloud)
        Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: const Color(0xFF2563EB), borderRadius: BorderRadius.circular(5)),
          child: const Text('115', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
    ];

  List<Widget> _touchBottom() => [
      StreamBuilder<bool>(
        stream: _player.stream.playing,
        builder: (_, _) => IconButton(
          icon: Icon(_player.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
          onPressed: () => unawaited(_player.playOrPause()),
        ),
      ),
      TouchClock(player: _player),
      const SizedBox(width: 8),
      Expanded(child: _TouchSeekBar(player: _player, drag: _dragF)),
      AnimatedBuilder(
        animation: _tools,
        builder: (_, _) => _BarButton(
          icon: _tools.subtitlesOn ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined,
          tooltip: '字幕',
          active: _panel.value == _Panel.subtitles,
          onPressed: () => _toggle(_Panel.subtitles),
        ),
      ),
      StreamBuilder<double>(
        stream: _player.stream.rate,
        builder: (_, _) => _BarTextButton(
          text: _player.state.rate == 1.0 ? '倍速' : '${_player.state.rate}x',
          tooltip: '播放速度',
          onPressed: () => _toggle(_Panel.speed),
        ),
      ),
      _BarButton(icon: Icons.settings_rounded, tooltip: '播放设置', onPressed: () => _toggle(_Panel.settings)),
    ];

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Video(
          controller: _video,
          controls: _controls,
          subtitleViewConfiguration: const SubtitleViewConfiguration(
            style: TextStyle(
              fontSize: 30,
              height: 1.35,
              color: Colors.white,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 4), Shadow(blurRadius: 8), Shadow(offset: Offset(1, 1), blurRadius: 2)],
            ),
            padding: EdgeInsets.fromLTRB(24, 0, 24, 28),
          ),
        ),
      );
    }
    final theme = _theme();
    return Scaffold(
      backgroundColor: Colors.black,
      body: MaterialDesktopVideoControlsTheme(
        normal: theme,
        fullscreen: theme,
        child: Video(
          controller: _video,
          controls: _controls,
          subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ---------------- player widgets (always dark: they sit on the video) ----------------

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    decoration: BoxDecoration(color: const Color(0xC0000000), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
  );
}

class _PanelBox extends StatelessWidget {
  const _PanelBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: buildTheme(Brightness.dark),
    child: Material(
      color: const Color(0xF01A1C22),
      elevation: 12,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: child),
    ),
  );
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(16, 10, trailing == null ? 16 : 8, 10),
    margin: const EdgeInsets.only(bottom: 4),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x22FFFFFF)))),
    child: Row(children: [
      Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5))),
      if (trailing != null) trailing!,
    ]),
  );
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 14, 4),
    child: Row(children: [
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600))),
      if (trailing != null) trailing!,
    ]),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.title, required this.onTap, this.selected = false, this.subtitle, this.icon, this.tag});

  final String title;
  final String? subtitle;
  final bool selected;
  final IconData? icon;
  final String? tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    hoverColor: const Color(0x14FFFFFF),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: icon != null
              ? Icon(icon, size: 18, color: Colors.white70)
              : (selected ? const Icon(Icons.check_rounded, size: 18, color: accent) : null),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: selected ? Colors.white : Colors.white.withValues(alpha: 0.88), fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(subtitle!, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
          ]),
        ),
        if (tag != null)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4)),
            child: Text(tag!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
      ]),
    ),
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.icon, required this.title, required this.value, required this.onChanged});

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    hoverColor: const Color(0x14FFFFFF),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
      child: Row(children: [
        SizedBox(width: 22, child: Icon(icon, size: 18, color: Colors.white70)),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13.5))),
        // the whole row is the button (a tap on the switch itself went nowhere)
        IgnorePointer(child: Transform.scale(scale: 0.8, child: Switch(value: value, onChanged: onChanged))),
      ]),
    ),
  );
}

class _Segment extends StatelessWidget {
  const _Segment({required this.text, required this.selected, required this.onTap});

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.25) : const Color(0x14FFFFFF),
        border: Border.all(color: selected ? accent : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: FontWeight.w600, fontSize: 13)),
    ),
  );
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.tooltip, required this.onPressed, this.active = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: onPressed,
      iconSize: 26,
      color: active ? accent : Colors.white,
      icon: Icon(icon),
    ),
  );
}

class _BarTextButton extends StatelessWidget {
  const _BarTextButton({required this.text, required this.tooltip, required this.onPressed});

  final String text;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(52, 40)),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
    ),
  );
}

/// The thumbnail and time above the seek bar while hovering it.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.width, required this.height, required this.label, this.sprite, this.tp, required this.seconds});

  final double width;
  final double height;
  final String label;
  final ui.Image? sprite;
  final Trickplay? tp;
  final double seconds;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    decoration: BoxDecoration(
      color: const Color(0xE6101216),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0x33FFFFFF)),
      boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 14, offset: Offset(0, 4))],
    ),
    padding: const EdgeInsets.all(4),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (sprite != null && tp != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(width: width - 8, height: height - 8, child: CustomPaint(painter: _SpritePainter(sprite!, tp!, seconds))),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
      ),
    ]),
  );
}

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.sprite, this.tp, this.seconds);

  final ui.Image sprite;
  final Trickplay tp;
  final double seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final i = tp.indexAt(seconds);
    final cols = tp.cols <= 0 ? 10 : tp.cols;
    final src = Rect.fromLTWH(((i % cols) * tp.w).toDouble(), ((i ~/ cols) * tp.h).toDouble(), tp.w.toDouble(), tp.h.toDouble());
    canvas.drawImageRect(sprite, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_SpritePainter old) => old.seconds != seconds || old.sprite != sprite;
}

/// A phone's seek bar: position, buffer, a big thumb; dragging shows where it would
/// land (the preview bubble above) and seeks on release.
class _TouchSeekBar extends StatefulWidget {
  const _TouchSeekBar({required this.player, required this.drag});

  final Player player;
  final ValueNotifier<double?> drag;

  @override
  State<_TouchSeekBar> createState() => _TouchSeekBarState();
}

class _TouchSeekBarState extends State<_TouchSeekBar> {
  final _subs = <StreamSubscription<Object?>>[];
  double _pos = 0, _buf = 0;
  double? _drag;

  @override
  void initState() {
    super.initState();
    void upd(_) {
      final d = widget.player.state.duration.inMilliseconds;
      if (!mounted || d <= 0) return;
      setState(() {
        _pos = widget.player.state.position.inMilliseconds / d;
        _buf = widget.player.state.buffer.inMilliseconds / d;
      });
    }
    _subs.add(widget.player.stream.position.listen(upd));
    _subs.add(widget.player.stream.buffer.listen(upd));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  void _set(double f) {
    setState(() => _drag = f.clamp(0.0, 1.0));
    widget.drag.value = _drag;
  }

  void _end() {
    final f = _drag;
    setState(() => _drag = null);
    widget.drag.value = null;
    final d = widget.player.state.duration;
    if (f != null && d > Duration.zero) unawaited(widget.player.seek(d * f));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth - 16;
      double fOf(double x) => (x - 8) / w;
      final f = (_drag ?? _pos).clamp(0.0, 1.0);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (e) => _set(fOf(e.localPosition.dx)),
        onHorizontalDragUpdate: (e) => _set(fOf(e.localPosition.dx)),
        onHorizontalDragEnd: (_) => _end(),
        onTapDown: (e) => _set(fOf(e.localPosition.dx)),
        onTapUp: (_) => _end(),
        child: SizedBox(
          height: 44,
          child: Stack(alignment: Alignment.centerLeft, children: [
            Positioned(left: 8, right: 8, child: Container(height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            Positioned(left: 8, width: w * _buf.clamp(0.0, 1.0), child: Container(height: 4, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2)))),
            Positioned(left: 8, width: w * f, child: Container(height: 4, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)))),
            Positioned(
              left: w * f,
              child: Container(
                width: _drag == null ? 14 : 20,
                height: _drag == null ? 14 : 20,
                decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
            ),
          ]),
        ),
      );
    },
  );
}
