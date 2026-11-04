import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../models.dart';
import 'stream_proxy.dart';
import 'subtitle_ball.dart';
import 'tools.dart';

class PlaySource {
  const PlaySource({required this.url, required this.cloud});

  final String url;

  /// A 115 file: played through the loopback proxy straight from the CDN.
  final bool cloud;
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.title, required this.code, required this.source, this.subtitles = const []});

  final String title;
  final String code;
  final PlaySource source;

  /// (name, url) of the subtitle files next to the video in the library.
  final List<(String, String)> subtitles;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      title: widget.title,
      // mpv draws the subtitles itself (ASS styles kept), so the subtitle ball's
      // position / size / colour apply
      libass: true,
      bufferSize: 64 << 20,
    ),
  );
  late final VideoController _video = VideoController(_player);
  late final JavPlayerTools _tools = JavPlayerTools(player: _player, code: widget.code);
  String? _status = '正在打开…';
  String? _error;
  final _subs = <StreamSubscription<Object?>>[];
  Duration _lastPos = Duration.zero;

  String get _posKey => 'pos.${widget.source.url.split('?').first}';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final native = _player.platform is NativePlayer ? _player.platform as NativePlayer : null;
    Future<void> set(String k, String v) async {
      try {
        await native?.setProperty(k, v);
      } catch (_) {}
    }

    await set('network-timeout', '20');
    await set('demuxer-max-bytes', '256MiB');
    await set('demuxer-max-back-bytes', '64MiB');
    await set('stream-lavf-o', 'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_streamed=1,reconnect_delay_max=5');
    await set('sub-font', 'Microsoft YaHei');
    await set('sub-auto', 'no');

    _subs.add(_player.stream.error.listen((e) {
      if (mounted) _tools.toast('播放出错: $e');
    }));
    _subs.add(_player.stream.position.listen((p) => _lastPos = p));
    _subs.add(_player.stream.playing.listen((playing) {
      if (playing && _status != null && mounted) setState(() => _status = null);
    }));

    var url = widget.source.url;
    var headers = App.api.authHeaders;
    if (widget.source.cloud) {
      setState(() => _status = '正在连接 115…');
      final local = await JavStreamProxy.instance.wrap(url, headers: App.api.authHeaders);
      if (local != url) {
        url = local;
        headers = const {}; // loopback: no login needed
      }
    }
    if (!mounted) return;
    setState(() => _status = '正在缓冲…');
    try {
      await _player.open(Media(url, httpHeaders: headers));
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开视频: $e');
      return;
    }
    await _tools.init();
    // the library's own subtitles: the first one ends up selected
    for (final (name, subUrl) in widget.subtitles.reversed) {
      await _tools.loadRemoteFile(name, subUrl, App.api.authHeaders, quiet: true);
    }
    await _resume();
  }

  /// Back to where this movie was left last time.
  Future<void> _resume() async {
    final saved = (await SharedPreferences.getInstance()).getInt(_posKey) ?? 0;
    if (saved < 30) return;
    final duration = await _player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(
      const Duration(seconds: 30),
      onTimeout: () => Duration.zero,
    );
    if (!mounted || duration == Duration.zero || saved > duration.inSeconds - 60) return;
    await _player.seek(Duration(seconds: saved));
    _tools.toast('从上次的 ${fmtClock(Duration(seconds: saved))} 继续');
  }

  @override
  void dispose() {
    final pos = _lastPos.inSeconds;
    final duration = _player.state.duration.inSeconds;
    unawaited(SharedPreferences.getInstance().then((p) {
      // finished (or barely started): next time from the start
      if (pos > 30 && (duration == 0 || pos < duration - 60)) {
        p.setInt(_posKey, pos);
      } else {
        p.remove(_posKey);
      }
    }));
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _tools.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  void _back(BuildContext context) {
    if (isFullscreen(context)) {
      unawaited(exitFullscreen(context));
    } else {
      Navigator.of(this.context).maybePop();
    }
  }

  // Keys for the whole player: the subtitle ball's (z / x / c by default), F for
  // fullscreen, Esc for back. Built inside the controls, so fullscreen has them too.
  KeyEventResult _onKey(BuildContext context, KeyEvent e) {
    if (_tools.handleKey(e)) return KeyEventResult.handled;
    if (e is! KeyDownEvent || _tools.panelFocused) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyF || e.logicalKey == LogicalKeyboardKey.enter) {
      unawaited(toggleFullscreen(context));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _back(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _volume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    unawaited(_player.setVolume(v));
    _tools.toast('音量 ${v.round()}');
  }

  static const _rates = [1.0, 1.25, 1.5, 2.0, 3.0];

  void _cycleRate() {
    final i = _rates.indexWhere((r) => (r - _player.state.rate).abs() < 0.01);
    final next = _rates[(i + 1) % _rates.length];
    unawaited(_player.setRate(next));
    _tools.toast('${next}x 倍速');
  }

  // The context of the controls themselves (not state.context, which stays the
  // non-fullscreen Video's): isFullscreen / exitFullscreen need the route they are in.
  Widget _controls(VideoState state) => Builder(builder: (context) => _overlay(state, context));

  Widget _overlay(VideoState state, BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(context, e),
      child: Stack(
        children: [
          MaterialDesktopVideoControls(state),
          Positioned.fill(child: JavSubtitleBall(tools: _tools, showBall: true)),
          if (_status != null || _error != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_error == null) ...[
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    const SizedBox(width: 12),
                  ],
                  Text(_error ?? _status!, style: TextStyle(color: _error == null ? Colors.white : Colors.redAccent)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  MaterialDesktopVideoControlsThemeData _theme(BuildContext context) => MaterialDesktopVideoControlsThemeData(
    seekBarThumbColor: const Color(0xFFE5484D),
    seekBarPositionColor: const Color(0xFFE5484D),
    toggleFullscreenOnDoublePress: true,
    keyboardShortcuts: {
      const SingleActivator(LogicalKeyboardKey.space): () => unawaited(_player.playOrPause()),
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () => unawaited(_player.playOrPause()),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _tools.queueSeek(-10),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => _tools.queueSeek(10),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _volume(5),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _volume(-5),
    },
    topButtonBar: [
      Builder(builder: (context) => MaterialDesktopCustomButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => _back(context),
      )),
      const SizedBox(width: 8),
      Expanded(
        child: Text(widget.title, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
      ),
      if (widget.source.cloud)
        const Padding(
          padding: EdgeInsets.only(right: 12),
          child: Text('115 直连', style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
    ],
    bottomButtonBar: [
      const MaterialDesktopPlayOrPauseButton(),
      MaterialDesktopCustomButton(icon: const Icon(Icons.replay_10), onPressed: () => _tools.queueSeek(-10)),
      MaterialDesktopCustomButton(icon: const Icon(Icons.forward_10), onPressed: () => _tools.queueSeek(10)),
      const MaterialDesktopVolumeButton(),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      MaterialDesktopCustomButton(icon: const Icon(Icons.speed), onPressed: _cycleRate),
      const MaterialDesktopFullscreenButton(),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = _theme(context);
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
