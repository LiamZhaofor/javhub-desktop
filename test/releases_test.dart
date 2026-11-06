import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/models.dart';

void main() {
  test('新片 from JavHub: the feed, what is unseen, the auto-wish setting', () {
    final r = Releases.fromJson({
      'items': [
        {'code': 'SSIS-990', 'cover': 'x/covers/SSIS-990.jpg', 'date': '2099-01-01', 'actor': '演员甲', 'magnet': 'sub', 'read': false, 'in_library': null, 'wished': true},
        {'code': 'SSIS-950', 'read': true, 'in_library': 'c~SSIS-950'},
      ],
      'unread': 1,
      'last_check': 1793980000.5,
      'follows': 2,
      'settings': {'auto_wish': true},
      'checking': false,
    });
    expect(r.items.map((i) => i.code), ['SSIS-990', 'SSIS-950']);
    expect((r.unread, r.follows, r.autoWish, r.checking), (1, 2, true, false));
    expect(r.items.first.wished && !r.items.first.read && r.items.first.magnet == 'sub', isTrue);
    expect(r.items.last.inLibrary, 'c~SSIS-950');
    expect(Releases.fromJson({}).items, isEmpty);
  });
}
