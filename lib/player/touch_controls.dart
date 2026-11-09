import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../motion.dart';
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
  Offset _tapAt = Offset.zero;
  int _tapSerial = 0;

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
    setState(() {
      _jump = (_jump != 0 && (_jump > 0) == forward ? _jump : 0) + (forward ? step : -step).round();
      _tapAt = d.localPosition;
      _tapSerial++;
    });
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
      // a double tap's jump, on its side: a ripple spreading from the finger, the count popping
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
              duration: _jump != 0 ? Motion.fast : Motion.medium,
              curve: _jump != 0 ? Motion.enter : Motion.exit,
              child: ClipPath(
                // the half-moon the side's shade is cut to (as the big video apps do)
                clipper: _SideClip(right: right),
                child: Stack(fit: StackFit.expand, children: [
                  const ColoredBox(color: Color(0x1FFFFFFF)),
                  if (_jump != 0 && (_jump > 0) == right)
                    _Ripple(key: ValueKey(_tapSerial), center: Offset(_tapAt.dx - (right ? w * 2 / 3 : 0), _tapAt.dy)),
                  Center(
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey('n$_tapSerial'),
                      tween: Tween(begin: 0.7, end: 1),
                      duration: Motion.settle,
                      curve: Motion.spring,
                      builder: (_, s, child) => Transform.scale(scale: s, child: child),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(right ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded, color: Colors.white, size: 34),
                        const SizedBox(height: 4),
                        Text('${_jump.abs()} 秒', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      // a sideways swipe: where it lands; a vertical one: the level
      IgnorePointer(
        child: Center(
          child: AnimatedSwitcher(
            duration: Motion.medium,
            switchInCurve: Motion.enter,
            switchOutCurve: Motion.exit,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: child),
            ),
            child: _swipeTo != null
                ? _Bubble(
                    '${_clock(_swipeTo!)}  ${_swipeTo! >= _swipeFrom ? '+' : '−'}${_clock((_swipeTo! - _swipeFrom).abs())}',
                    key: const ValueKey('swipe'),
                  )
                : _levelLabel != null
                ? _Level(key: ValueKey('level$_swipeLeft'), brightness: _swipeLeft ?? _levelLabel!.startsWith('亮'), value: _level)
                : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ),
      ),
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
            offset: _visible ? Offset.zero : const Offset(0, -0.5),
            duration: _visible ? Motion.slow : Motion.medium,
            curve: _visible ? Motion.enter : Motion.exit,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: _visible ? Motion.medium : Motion.fast,
              curve: _visible ? Motion.enter : Motion.exit,
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
            offset: _visible ? Offset.zero : const Offset(0, 0.5),
            duration: _visible ? Motion.slow : Motion.medium,
            curve: _visible ? Motion.enter : Motion.exit,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: _visible ? Motion.medium : Motion.fast,
              curve: _visible ? Motion.enter : Motion.exit,
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
              scale: _visible ? 1 : 0.7,
              duration: _visible ? Motion.settle : Motion.fast,
              curve: _visible ? Motion.spring : Motion.exit,
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: _visible ? Motion.medium : Motion.fast,
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
                        duration: Motion.medium,
                        switchInCurve: Motion.spring,
                        switchOutCurve: Motion.exit,
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: RotationTransition(turns: Tween(begin: -0.08, end: 0.0).animate(a), child: ScaleTransition(scale: a, child: child)),
                        ),
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

/// The side's shade: a half-moon bulging toward the middle of the picture.
class _SideClip extends CustomClipper<Path> {
  const _SideClip({required this.right});

  final bool right;

  @override
  Path getClip(Size s) {
    final p = Path();
    if (right) {
      p.moveTo(s.width, 0);
      p.lineTo(s.width * 0.28, 0);
      p.quadraticBezierTo(-s.width * 0.18, s.height / 2, s.width * 0.28, s.height);
      p.lineTo(s.width, s.height);
    } else {
      p.moveTo(0, 0);
      p.lineTo(s.width * 0.72, 0);
      p.quadraticBezierTo(s.width * 1.18, s.height / 2, s.width * 0.72, s.height);
      p.lineTo(0, s.height);
    }
    return p..close();
  }

  @override
  bool shouldReclip(_SideClip old) => old.right != right;
}

/// A ring of light spreading from where the finger tapped, fading as it goes.
class _Ripple extends StatefulWidget {
  const _Ripple({super.key, required this.center});

  final Offset center;

  @override
  State<_Ripple> createState() => _RippleState();
}

class _RippleState extends State<_Ripple> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => CustomPaint(painter: _RipplePainter(widget.center, Motion.enter.transform(_c.value))),
  );
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.center, this.t);

  final Offset center;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.longestSide * 0.75 * t;
    canvas.drawCircle(center, r, Paint()..color = Colors.white.withValues(alpha: 0.22 * (1 - t)));
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.center != center;
}

/// Brightness / volume while swiping up and down: an icon and a bar that fills.
class _Level extends StatelessWidget {
  const _Level({super.key, required this.brightness, required this.value});

  final bool brightness;
  final double value;

  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(color: const Color(0xC0000000), borderRadius: BorderRadius.circular(22)),
    child: Row(children: [
      Icon(
        brightness
            ? (value < 0.34 ? Icons.brightness_low_rounded : value < 0.67 ? Icons.brightness_medium_rounded : Icons.brightness_high_rounded)
            : (value == 0 ? Icons.volume_off_rounded : value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
        color: Colors.white,
        size: 22,
      ),
      const SizedBox(width: 12),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: value),
            duration: Motion.fast,
            builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 5, color: Colors.white, backgroundColor: Colors.white24),
          ),
        ),
      ),
    ]),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.text, {super.key});

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
