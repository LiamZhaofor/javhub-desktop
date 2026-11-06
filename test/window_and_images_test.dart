import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/player/player_page.dart';
import 'package:javhub_desktop/player/player_window.dart';
import 'package:javhub_desktop/player/settings.dart';
import 'package:javhub_desktop/widgets.dart';

/// The smallest JPEG header that says its size: SOI, an APP0 segment, SOF0.
Uint8List jpegHeader(int w, int h, {int sof = 0xC0}) => Uint8List.fromList([
  0xFF, 0xD8, //
  0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, 2 bytes of payload
  0xFF, 0xC4, 0x00, 0x03, 0x00, // DHT: not a frame header
  0xFF, sof, 0x00, 0x0B, 0x08, h >> 8, h & 0xFF, w >> 8, w & 0xFF, 0x03, 0x01, 0x22, 0x00,
]);

void main() {
  test('the shape of a JPEG or PNG is read from its header', () {
    expect(imageAspect(jpegHeader(800, 450)), closeTo(16 / 9, 1e-9));
    expect(imageAspect(jpegHeader(380, 538, sof: 0xC2)), closeTo(380 / 538, 1e-9)); // progressive
    final png = Uint8List(32)
      ..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..buffer.asByteData().setUint32(16, 960)
      ..buffer.asByteData().setUint32(20, 540);
    expect(imageAspect(png), closeTo(16 / 9, 1e-9));
    expect(imageAspect(Uint8List.fromList([1, 2, 3])), isNull);
    // a sleeve (back + spine + front, DVD or Blu-ray) is not one picture; a 16:9 one is
    expect(isOnePicture(800 / 538), isFalse);
    expect(isOnePicture(800 / 438), isFalse);
    expect(isOnePicture(800 / 450), isTrue);
    expect(isOnePicture(960 / 540), isTrue);
    expect(isOnePicture(null), isFalse);
  });

  test('a player window gets everything it needs on its command line', () {
    const args = PlayerArgs(
      title: 'ABF-338 生ハメ騎乗位',
      code: 'ABF-338',
      itemId: 'c~ABF-338',
      part: 1,
      source: PlaySource(url: 'http://127.0.0.1:5555/s/3/ABF-338.mp4', cloud: true, local: true),
      subtitles: [('ABF-338.zh.srt', 'https://x/media/c~ABF-338/ABF-338.zh.srt')],
      start: 1234,
      from: 'Android',
      lanBase: 'http://192.168.31.11:8930',
      bounds: Rect.fromLTWH(10, 20, 1440, 900),
      maximized: true,
    );
    final enc = args.encode();
    expect(RegExp(r'^[A-Za-z0-9_=-]+$').hasMatch(enc), isTrue, reason: 'one plain command-line argument');
    final back = PlayerArgs.decode(enc);
    expect(back.title, args.title);
    expect(back.code, 'ABF-338');
    expect(back.itemId, 'c~ABF-338');
    expect(back.part, 1);
    expect(back.source.url, args.source.url);
    expect(back.source.cloud && back.source.local, isTrue);
    expect(back.subtitles, args.subtitles);
    expect((back.start, back.from), (1234, 'Android'));
    expect(back.lanBase, 'http://192.168.31.11:8930');
    expect(back.bounds, const Rect.fromLTWH(10, 20, 1440, 900));
    expect(back.maximized, isTrue);
  });

  test('自动加载在线字幕 is kept with the player settings, off by default', () {
    expect(JavPlayerSettings().autoSubtitle, isFalse);
    final s = JavPlayerSettings()..autoSubtitle = true;
    expect(JavPlayerSettings.fromJson(s.toJson()).autoSubtitle, isTrue);
    expect(JavPlayerSettings.fromJson({}).autoSubtitle, isFalse);
  });
}
