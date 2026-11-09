import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'tools.dart';

/// The phone's player controls (instead of media_kit's, which show their bars the moment a
/// finger touches the screen - a long press or a swipe popped them up too):
///   tap               bars on / off
///   double tap        left third back, right third forward ([JavPlayerSettings.seekStep]),
///                     middle play / pause
///   long press        the accelerate speed while held, no bars
///   swipe sideways    choose a new position (the preview bubble follows), it plays from
///                     there on release
///   swipe up / down   left half brightness, right half volume
class TouchControls extends StatefulWidget {
  const TouchControls({
    super.key,
    required this.player,
    required this.tools,
    required this.topBar,
    required this.bottomBar,
    required this.drag,
    required this.panelOpen,
  });

  final Player player;
  final JavPlayerTools tools;
  final List<Widget> topBar;
  final List<Widget> bottomBar;

  /// Where a sideways swipe would land (0-1): the player draws the preview bubble.
  final ValueNotifier<double?> drag;

  /// A menu is open: the bars stay.
  final ValueListenable<Object?> panelOpen;

  @override
  State<TouchControls> createState() => _TouchControlsState();
}

class _TouchControlsState extends State<TouchControls> {
  static const _screen = MethodChannel('javhub/screen');

  bool _visible = true;
  Timer? _hide;
  final _subs = <StreamSubscription<Object?>>[];
  bool _playing = false;
  bool _buffering = false;

  // a double tap's jump, shown on its side for a moment
  int _jump = 0; // seconds, sign = direction
  Timer? _jumpTimer;

  // sideways swipe
  double? _swipeStartX;
  Duration _swipeFrom = Duration.zero;
  Duration? _swipeTo;

  // vertical swipe
  bool? _swipeLeft;
  double _level = 0;
  String? _levelLabel;
  Timer? _levelTimer;
  bool _brightnessChanged = false;

  Player get _p => widget.player;

  @override
  void initState() {
    super.initState();
    _playing = _p.state.playing;
    _buffering = _p.state.buffering;
    _subs.add(_p.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
      _scheduleHide();
    }));
    _subs.add(_p.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    widget.panelOpen.addListener(_onPanel);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _jumpTimer?.cancel();
    _levelTimer?.cancel();
    widget.panelOpen.removeListener(_onPanel);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    if (_brightnessChanged) unawaited(_screen.invokeMethod('setBrightness', {'value': -1.0}).catchError((_) {}));
    super.dispose();
  }

  void _onPanel() {
    if (widget.panelOpen.value != null) {
      _hide?.cancel();
      if (!_visible) setState(() => _visible = true);
    } else {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (!_playing || widget.panelOpen.value != null) return;
    _hide = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && widget.panelOpen.value == null) setState(() => _visible = false);
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggle() {
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  // ---------------- gestures ----------------

  void _doubleTap(TapDownDetails d, double width) {
    final x = d.localPosition.dx;
    if (x > width / 3 && x < width * 2 / 3) {
      unawaited(_p.playOrPause());
      return;
    }
    final step = widget.tools.settings.seekStep;
    final forward = x >= width * 2 / 3;
    // a second double tap on the same side while the first still shows adds up
    setState(() => _jump = (_jump != 0 && (_jump > 0) == forward ? _jump : 0) + (forward ? step : -step).round());
    widget.tools.queueSeek(forward ? step : -step);
    _jumpTimer?.cancel();
    _jumpTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _jump = 0);
    });
  }

  void _swipeStart(DragStartDetails d) {
    if (_p.state.duration <= Duration.zero) return;
    _swipeStartX = d.localPosition.dx;
    _swipeFrom = _p.state.position;
    _swipeTo = _swipeFrom;
  }

  void _swipeUpdate(DragUpdateDetails d, double width) {
    final start = _swipeStartX;
    final duration = _p.state.duration;
    if (start == null || duration <= Duration.zero || width <= 0) return;
    // the screen's width is a sixth of the movie, between 1 and 5 minutes
    final perWidth = (duration.inSeconds / 6).clamp(60, 300);
    final delta = (d.localPosition.dx - start) / width * perWidth;
    var to = _swipeFrom + Duration(milliseconds: (delta * 1000).round());
    if (to < Duration.zero) to = Duration.zero;
    if (to > duration) to = duration;
    setState(() => _swipeTo = to);
    widget.drag.value = to.inMilliseconds / duration.inMilliseconds;
  }

  void _swipeEnd() {
    final to = _swipeTo;
    _swipeStartX = null;
    _swipeTo = null;
    widget.drag.value = null;
    if (mounted) setState(() {});
    if (to != null && (to - _swipeFrom).abs() > const Duration(seconds: 1)) unawaited(_p.seek(to));
  }

  Future<void> _levelStart(DragStartDetails d, double width) async {
    _swipeLeft = d.localPosition.dx < width / 2;
    try {
      _level = ((await _screen.invokeMethod<double>(_swipeLeft! ? 'getBrightness' : 'getVolume')) ?? 0.5).clamp(0.0, 1.0);
    } catch (_) {
      _level = _swipeLeft! ? 0.5 : _p.state.volume / 100;
    }
  }

  void _levelUpdate(DragUpdateDetails d, double height) {
    final left = _swipeLeft;
    if (left == null || height <= 0) return;
    _level = (_level - d.delta.dy / (height * 0.8)).clamp(0.0, 1.0);
    if (left) {
      _brightnessChanged = true;
      unawaited(_screen.invokeMethod('setBrightness', {'value': _level}).catchError((_) {}));
    } else {
      unawaited(_screen.invokeMethod('setVolume', {'value': _level}).catchError((_) => _p.setVolume(_level * 100)));
    }
    setState(() => _levelLabel = '${left ? '亮度' : '音量'} ${(_level * 100).round()}%');
    _levelTimer?.cancel();
    _levelTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _levelLabel = null);
    });
  }

  // ---------------- drawing ----------------

  static String _clock(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Widget _bar(List<Widget> children, {required bool top}) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: top ? Alignment.topCenter : Alignment.bottomCenter,
        end: top ? Alignment.bottomCenter : Alignment.topCenter,
        colors: const [Color(0xB3000000), Color(0x00000000)],
      ),
    ),
    child: SafeArea(
      top: top,
      bottom: !top,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, top ? 6 : 18, 12, top ? 18 : 6),
        child: Row(children: children),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    final w = c.maxWidth, h = c.maxHeight;
    return Stack(fit: StackFit.expand, children: [
      // the gestures, under the bars
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        onDoubleTapDown: (d) => _doubleTap(d, w),
        onDoubleTap: () {},
        onLongPressStart: (_) => unawaited(widget.tools.startAcceleration()),
        onLongPressEnd: (_) => unawaited(widget.tools.stopAcceleration()),
        onLongPressCancel: () => unawaited(widget.tools.stopAcceleration()),
        onHorizontalDragStart: _swipeStart,
        onHorizontalDragUpdate: (d) => _swipeUpdate(d, w),
        onHorizontalDragEnd: (_) => _swipeEnd(),
        onHorizontalDragCancel: _swipeEnd,
        onVerticalDragStart: (d) => unawaited(_levelStart(d, w)),
        onVerticalDragUpdate: (d) => _levelUpdate(d, h),
        onVerticalDragEnd: (_) => _swipeLeft = null,
      ),
      // a double tap's jump, on its side
      for (final right in [false, true])
        Positioned(
          left: right ? null : 0,
          right: right ? 0 : null,
          top: 0,
          bottom: 0,
          width: w / 3,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _jump != 0 && (_jump > 0) == right ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: right ? const Alignment(0.6, 0) : const Alignment(-0.6, 0),
                    radius: 0.9,
                    colors: const [Color(0x40FFFFFF), Color(0x00FFFFFF)],
                  ),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(right ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded, color: Colors.white, size: 34),
                  const SizedBox(height: 4),
                  Text('${_jump.abs()} 秒', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        ),
      // a sideways swipe: where it lands
      if (_swipeTo != null)
        IgnorePointer(
          child: Center(
            child: _Bubble(
              '${_clock(_swipeTo!)}  ${_swipeTo! >= _swipeFrom ? '+' : '−'}${_clock((_swipeTo! - _swipeFrom).abs())}',
            ),
          ),
        ),
      if (_levelLabel != null) IgnorePointer(child: Center(child: _Bubble(_levelLabel!))),
      if (_buffering && _swipeTo == null)
        const IgnorePointer(
          child: Center(child: SizedBox(width: 42, height: 42, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))),
        ),
      // the bars
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: IgnorePointer(
          ignoring: !_visible,
          child: AnimatedSlide(
            offset: _visible ? Offset.zero : const Offset(0, -0.4),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Listener(onPointerDown: (_) => _show(), child: _bar(widget.topBar, top: true)),
            ),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
          ignoring: !_visible,
          child: AnimatedSlide(
            offset: _visible ? Offset.zero : const Offset(0, 0.4),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Listener(onPointerDown: (_) => _show(), child: _bar(widget.bottomBar, top: false)),
            ),
          ),
        ),
      ),
      // play / pause in the middle while the bars show
      if (!_buffering)
        Center(
          child: IgnorePointer(
            ignoring: !_visible,
            child: AnimatedScale(
              scale: _visible ? 1 : 0.8,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Material(
                  color: const Color(0x66000000),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      unawaited(_p.playOrPause());
                      _scheduleHide();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                        child: Icon(
                          _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          key: ValueKey(_playing),
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  });
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(color: const Color(0xC0000000), borderRadius: BorderRadius.circular(22)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
  );
}

/// The phone's position / length label for the bottom bar.
class TouchClock extends StatelessWidget {
  const TouchClock({super.key, required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: player.stream.position,
    builder: (_, _) => Text(
      '${_TouchControlsState._clock(player.state.position)} / ${_TouchControlsState._clock(player.state.duration)}',
      style: const TextStyle(color: Colors.white, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
    ),
  );
}
