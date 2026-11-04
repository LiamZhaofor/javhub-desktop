import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/models.dart';
import 'package:javhub_desktop/player/tools.dart';

void main() {
  test('library items read leniently', () {
    final items = parseLibrary([
      {
        'id': 'c~SSIS-469', 'code': 'SSIS-469', 'folder': 'SSIS-469', 'title': 'SSIS-469 幼なじみ姉妹の妹', 'actors': ['A', 'B', 'C'],
        'cloud': true, 'poster': true, 'pv': 1793770000, 'videos': ['SSIS-469.strm'], 'chinese_sub': false,
        'sources': ['/115/JAV/SSIS-469.mp4'], 'mtime': 1793770000.5, 'category': '有码',
      },
      {'id': 'X', 'code': 'ABC-001', 'folder': 'ABC-001', 'title': null, 'actors': 'not a list', 'pv': '12', 'size': 'x'},
      'garbage',
    ]);
    expect(items.length, 2);
    expect(items[0].cloud && items[0].poster, isTrue);
    expect(items[0].posterVersion, 1793770000);
    expect(items[0].shortTitle, '幼なじみ姉妹の妹');
    expect(items[1].actors, isEmpty);
    expect(items[1].posterVersion, 12);
    expect(items[1].size, 0);
    expect(items[0].matches('姉妹'), isTrue);
    expect(items[0].matches('b'), isTrue);
    expect(items[0].matches('zzz'), isFalse);
  });

  test('the title under a tile drops the code, falls back to the actresses', () {
    expect(shortenTitle('[SSIS-001] 标题', 'SSIS-001', const []), '标题');
    expect(shortenTitle('SSIS-001', 'SSIS-001', const ['甲', '乙', '丙']), '甲 乙');
    expect(shortenTitle('别的标题', 'SSIS-001', const []), '别的标题');
  });

  test('search results and jobs', () {
    final r = SearchResult.fromJson({
      'code': 'SSIS-469', 'found': true,
      'movie': {'title': 'T', 'actors': ['A'], 'runtime': 150, 'samples': ['u1', 'u2']},
      'candidates': [
        {'title': 'a', 'size_h': '5.2 GB', 'magnet': 'magnet:?xt=1', 'score': 88, 'reasons': ['中文字幕'], 'rejected': ''},
        {'title': 'b', 'magnet': 'magnet:?xt=2', 'score': 10, 'reasons': [], 'rejected': '太小'},
      ],
      'sources': [{'source': 'javbus', 'ok': true, 'count': 2}],
      'in_library': [{'id': 'SSIS-469', 'code': 'SSIS-469', 'folder': 'SSIS-469', 'chinese_sub': true}],
      'active_job': null,
    });
    expect(r.usable.length, 1);
    expect(r.movie.runtime, 150);
    expect(r.inLibrary.single.chineseSub, isTrue);
    expect(r.activeJob, isNull);

    final j = Job.fromJson({'id': 'ab12', 'status': 'downloading', 'progress': 0.42, 'log': [[1793770000, '开始'], 'bad']});
    expect(j.active, isTrue);
    expect(j.log.single.$2, '开始');
    expect(Backend('cloud:115 Cloud', true).title, '115 网盘');
    expect(Backend('qbittorrent', true).title, 'NAS 本地');
    expect(Backend('offline:PikPak', true).title, 'PikPak 离线 → NAS');
  });

  test('formatting', () {
    expect(fmtSize(0), '?');
    expect(fmtSize(5.5 * 1024 * 1024 * 1024), '5.5GB');
    expect(fmtEta(3725), '1时2分');
    expect(fmtClock(const Duration(hours: 2, minutes: 29, seconds: 48)), '2:29:48');
    expect(fmtAgo(1000, DateTime.fromMillisecondsSinceEpoch(1000 * 1000 + 7200 * 1000)), '2 小时前');
  });

  test('Xunlei subtitles: format from "ext", duration kept', () {
    final subs = parseXunleiSubtitles({
      'code': 0,
      'data': [
        {'url': 'https://subtitle.v.geilijiasu.com/22/E0/22E0', 'ext': 'srt', 'name': 'SSIS-469.srt', 'duration': '8988845', 'extra_name': '（网友上传）'},
        {'url': 'https://x/y.exe', 'ext': 'exe', 'name': 'bad'},
      ],
    });
    expect(subs.single.ext, 'srt');
    expect(subs.single.duration, const Duration(milliseconds: 8988845));
    expect(subs.single.label, 'SSIS-469.srt (（网友上传）)');
    expect(parseXunleiSubtitles({'code': 1}), isEmpty);
  });
}
