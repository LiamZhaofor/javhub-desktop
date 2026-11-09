import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// The phone's player and the system around it (Android):
///  - 小窗 (picture in picture): while a movie plays, going home shrinks it into a small
///    window (play / pause, back, forward on it); [enterSmallWindow] does it from a button.
///  - the media session: ColorOS 流体云, the control centre, the lock screen and headset
///    buttons show and control what is playing.
/// The commands come back through [onCommand]; [inSmallWindow] says when the player should
/// show nothing but the picture.
class AndroidPlayback {
  AndroidPlayback({required this.player, required this.title, required this.subtitle, required this.onCommand});

  static const _pip = MethodChannel('javhub/pip');
  static const _media = MethodChannel('javhub/media');

  static bool get supported => Platform.isAndroid;

  final Player player;
  final String title;
  final String subtitle;

  /// play / pause / rewind / forward / seek:<ms>
  final void Function(String command) onCommand;

  final inSmallWindow = ValueNotifier<bool>(false);
  final _subs = <StreamSubscription<Object?>>[];
  Uint8List? _art;
  bool _artSent = false;
  Timer? _tick;
  bool _stopped = false;

  void start() {
    if (!supported) return;
    _pip.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          inSmallWindow.value = call.arguments == true;
        case 'stopped':
          // the small window was closed with its ✕, or the phone went to sleep: pause
          if (!inSmallWindow.value) unawaited(player.pause());
      }
      return null;
    });
    _media.setMethodCallHandler((call) async {
      if (call.method == 'command' && call.arguments is String) onCommand(call.arguments as String);
      return null;
    });
    _subs.add(player.stream.playing.listen((_) {
      _pipState();
      _send();
    }));
    _subs.add(player.stream.rate.listen((_) => _send()));
    // (a seek: the position jumps - and buffering comes and goes with it)
    _subs.add(player.stream.buffering.listen((_) => _send()));
    _subs.add(player.stream.width.listen((_) => _pipState()));
    _subs.add(player.stream.duration.listen((_) => _send()));
    // the system runs the position on by itself from the last state; now and then the true one
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => _send());
    _pipState();
  }

  /// The poster, for the notification and 流体云 (sent once).
  set artwork(Uint8List? bytes) {
    _art = bytes;
    _artSent = false;
    _send();
  }

  /// Said after a seek: the system's position jumps with it.
  void seeked() => _send();

  Future<bool> enterSmallWindow() async {
    if (!supported) return false;
    try {
      return await _pip.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }

  void _pipState() {
    if (_stopped) return;
    final w = player.state.width ?? 16, h = player.state.height ?? 9;
    unawaited(_pip.invokeMethod('setEnabled', {
      'enabled': true,
      'w': w > 0 ? w : 16,
      'h': h > 0 ? h : 9,
      'playing': player.state.playing,
    }).catchError((_) {}));
  }

  void _send() {
    if (_stopped || player.state.duration <= Duration.zero) return;
    final art = !_artSent ? _art : null;
    if (art != null) _artSent = true;
    unawaited(_media.invokeMethod('update', {
      'title': title,
      'subtitle': subtitle,
      'playing': player.state.playing,
      'position': player.state.position.inMilliseconds,
      'duration': player.state.duration.inMilliseconds,
      'speed': player.state.rate,
      'art': ?art,
    }).catchError((_) {}));
  }

  void stop() {
    if (!supported || _stopped) return;
    _stopped = true;
    _tick?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_pip.invokeMethod('setEnabled', {'enabled': false}).catchError((_) {}));
    unawaited(_media.invokeMethod('stop').catchError((_) {}));
    _pip.setMethodCallHandler(null);
    _media.setMethodCallHandler(null);
    inSmallWindow.dispose();
  }
}
