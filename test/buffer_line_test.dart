import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/player/tools.dart';

void main() {
  const ahead = 256 << 20;
  const speed = '3156000'; // ~3 MB/s, a 4K movie's bitrate

  test('a cache still filling shows the download speed', () {
    expect(bufferLine(seconds: '20.04', cacheState: '{"fw-bytes":60000000,"eof-cached":false}', speed: '16000000', aheadBytes: ahead),
        '缓冲    20.0 秒   下载 15.26 MB/s');
  });

  test('a full cache says it is full and reads at the playback rate', () {
    expect(bufferLine(seconds: '85.3', cacheState: '{"fw-bytes":${ahead - 300000},"eof-cached":false}', speed: speed, aheadBytes: ahead),
        '缓冲    85.3 秒（已满）   按播放读取 3.01 MB/s');
  });

  test('a cache that reached the end of the file says so', () {
    expect(bufferLine(seconds: '40', cacheState: '{"fw-bytes":1000,"eof-cached":true}', speed: '0', aheadBytes: ahead), '缓冲    40.0 秒（已到片尾）');
  });

  test('missing values do not break the line', () {
    expect(bufferLine(seconds: '', cacheState: '', speed: '', aheadBytes: ahead), '缓冲    - 秒   下载 0.00 MB/s');
  });
}
