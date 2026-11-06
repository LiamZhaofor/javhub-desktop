/// JavHub's JSON, read leniently: a field that is missing or of another type
/// becomes empty instead of throwing (the server adds fields over time).
library;

String _s(Object? v) => v == null ? '' : '$v';
int _i(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
bool _b(Object? v) => v == true || v == 1 || v == '1';
List<String> _ls(Object? v) => v is List ? [for (final x in v) if (x != null) '$x'] : const [];
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

List<LibraryItem> parseLibrary(Object? items) =>
    items is List ? [for (final it in items) if (it is Map) LibraryItem.fromJson(it.cast<String, dynamic>())] : [];

class LibraryItem {
  LibraryItem({
    required this.id,
    required this.code,
    required this.folder,
    this.title = '',
    this.actors = const [],
    this.studio = '',
    this.series = '',
    this.tags = const [],
    this.date = '',
    this.category = '',
    this.leak = false,
    this.chineseSub = false,
    this.cloud = false,
    this.poster = false,
    this.posterVersion = 0,
    this.fanart = false,
    this.videos = const [],
    this.subs = const [],
    this.sources = const [],
    this.size = 0,
    this.mtime = 0,
    this.plot = '',
    this.stills = const [],
    this.watchedAt = 0,
    this.progress,
    this.fav = false,
    this.rating = 0,
    this.watched = false,
    this.watchedSet = false,
  });

  factory LibraryItem.fromJson(Map<String, dynamic> j) => LibraryItem(
    id: _s(j['id']),
    code: _s(j['code']),
    folder: _s(j['folder']),
    title: _s(j['title']),
    actors: _ls(j['actors']),
    studio: _s(j['studio']),
    series: _s(j['series']),
    tags: _ls(j['tags']),
    date: _s(j['date']),
    category: _s(j['category']),
    leak: _b(j['leak']),
    chineseSub: _b(j['chinese_sub']),
    cloud: _b(j['cloud']),
    poster: _b(j['poster']),
    posterVersion: _i(j['pv']),
    fanart: _b(j['fanart']),
    videos: _ls(j['videos']),
    subs: _ls(j['subs']),
    sources: _ls(j['sources']),
    size: _i(j['size']),
    mtime: _d(j['mtime']),
    plot: _s(j['plot']),
    stills: _ls(j['stills']),
    watchedAt: _d(j['watched_at']),
    progress: j['progress'] is Map ? Progress.fromJson(_m(j['progress'])) : null,
    fav: _b(j['fav']),
    rating: _i(j['rating']),
    watched: _b(j['watched']),
    watchedSet: _b(j['watched_set']),
  );

  final String id;
  final String code;
  final String folder;
  final String title;
  final List<String> actors;
  final String studio;
  final String series;
  final List<String> tags;
  final String date;
  final String category;
  final bool leak;
  final bool chineseSub;
  final bool cloud;
  final bool poster;
  final int posterVersion;
  final bool fanart;
  final List<String> videos;
  final List<String> subs;
  final List<String> sources;
  final int size;
  final double mtime;
  final String plot;

  /// Stills (剧照) in extrafanart/, only in the full item.
  final List<String> stills;

  /// When it was last played (home page).
  final double watchedAt;

  /// How far it was watched, on any device (home page).
  final Progress? progress;

  // My marks, shared by every copy with this code; changed in place when set.
  bool fav;
  int rating; // 0 .. 5
  bool watched; // set by hand, or played to the end
  bool watchedSet;

  void applyMarks(Map<String, dynamic> m) {
    fav = _b(m['fav']);
    rating = _i(m['rating']);
    watched = _b(m['watched']);
    watchedSet = _b(m['watched_set']);
  }

  /// The title without the code it usually starts with; the actresses when
  /// there is no title (as under the web library's tiles).
  String get shortTitle => shortenTitle(title, code, actors);

  bool matches(String q) {
    if (q.isEmpty) return true;
    final l = q.toLowerCase();
    return [code, folder, title, studio, series, ...actors, ...tags].any((x) => x.toLowerCase().contains(l));
  }
}

String shortenTitle(String title, String code, List<String> actors) {
  var t = title.trim();
  final c = code.toUpperCase();
  final head = t.replaceFirst(RegExp(r'^[\[(【]\s*'), '');
  if (c.isNotEmpty && head.toUpperCase().startsWith(c)) {
    t = head.substring(c.length).replaceFirst(RegExp(r'^[\])】\s:：\-]+'), '').trim();
  }
  return t.isNotEmpty && t.toUpperCase() != c ? t : actors.take(2).join(' ');
}

class Movie {
  Movie(this.j);

  final Map<String, dynamic> j;
  String get title => _s(j['title']);
  String get cover => _s(j['cover']);
  String get date => _s(j['date']);
  int get runtime => _i(j['runtime']);
  List<String> get actors => _ls(j['actors']);
  String get studio => _s(j['studio']);
  String get label => _s(j['label']);
  String get series => _s(j['series']);
  String get director => _s(j['director']);
  List<String> get tags => _ls(j['tags']);
  List<String> get samples => _ls(j['samples']);
}

class Candidate {
  Candidate(this.j);

  final Map<String, dynamic> j;
  String get title => _s(j['title']);
  String get size => _s(j['size_h']);
  String get magnet => _s(j['magnet']);
  num get score => j['score'] is num ? j['score'] as num : 0;
  List<String> get reasons => _ls(j['reasons']);
  String get rejected => _s(j['rejected']);
  List<String> get sources => _ls(j['sources']);
}

class SearchResult {
  SearchResult({
    required this.code,
    required this.found,
    required this.movie,
    required this.candidates,
    required this.sources,
    required this.inLibrary,
    this.activeJob,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    code: _s(j['code']),
    found: _b(j['found']),
    movie: Movie(_m(j['movie'])),
    candidates: [for (final c in (j['candidates'] as List? ?? [])) if (c is Map) Candidate(c.cast<String, dynamic>())],
    sources: [for (final s in (j['sources'] as List? ?? [])) if (s is Map) s.cast<String, dynamic>()],
    inLibrary: parseLibrary(j['in_library']),
    activeJob: j['active_job'] is Map ? _m(j['active_job']) : null,
  );

  final String code;
  final bool found;
  final Movie movie;
  final List<Candidate> candidates;
  final List<Map<String, dynamic>> sources;
  final List<LibraryItem> inLibrary;
  final Map<String, dynamic>? activeJob;

  List<Candidate> get usable => candidates.where((c) => c.rejected.isEmpty).toList();
}

class Backend {
  Backend(this.name, this.ok);

  final String name;
  final bool ok;

  /// Where a download ends up, in plain words (as the web UI says it).
  String get title {
    final tool = name.contains(':') ? name.split(':')[1].replaceFirst(RegExp(r' Cloud$'), '') : '';
    if (name == 'qbittorrent') return 'NAS 本地';
    if (name.startsWith('cloud:')) return '$tool 网盘';
    return '$tool 离线 → NAS';
  }

  String get subtitle {
    if (name == 'qbittorrent') return 'qBittorrent BT 下载到 NAS 硬盘';
    if (name.startsWith('cloud:')) return '网盘离线下载，只存网盘不占 NAS';
    return '先在网盘离线下载，完成后拉回 NAS';
  }
}

class Backends {
  Backends(this.items, this.preferred);

  factory Backends.fromJson(Map<String, dynamic> j) => Backends(
    [for (final b in (j['backends'] as List? ?? [])) if (b is Map) Backend(_s(b['name']), _b(b['ok']))],
    _s(j['default']),
  );

  final List<Backend> items;
  final String preferred;
}

const jobStatusText = {
  'queued': '排队中',
  'searching': '搜索中',
  'downloading': '下载中',
  'organizing': '整理中',
  'done': '已完成',
  'failed': '失败',
  'canceled': '已取消',
};
const activeJobStatus = {'queued', 'searching', 'downloading', 'organizing'};

class Job {
  Job(this.j);

  factory Job.fromJson(Map<String, dynamic> j) => Job(j);

  final Map<String, dynamic> j;
  String get id => _s(j['id']);
  String get code => _s(j['code']);
  String get title => _s(j['title']);
  String get status => _s(j['status']);
  String get backend => _s(j['backend']);
  double get progress => _d(j['progress']);
  int get size => _i(j['size']);
  int get speed => _i(j['speed']);
  int get eta => _i(j['eta']);
  double get created => _d(j['created']);
  String get result => _s(j['result_path']).isNotEmpty ? _s(j['result_path']) : _s(j['message']);
  bool get active => activeJobStatus.contains(status);
  List<(double, String)> get log => [
    for (final e in (j['log'] as List? ?? []))
      if (e is List && e.length >= 2) (_d(e[0]), _s(e[1])),
  ];
}

class BlockedMovie {
  const BlockedMovie({required this.code, this.title = '', this.cover = '', this.item, this.poster = false, this.posterVersion = 0, this.at = 0});

  factory BlockedMovie.fromJson(Map<String, dynamic> j) => BlockedMovie(
    code: '${j['code'] ?? ''}',
    title: '${j['title'] ?? ''}',
    cover: '${j['cover'] ?? ''}',
    item: j['item'] as String?,
    poster: j['poster'] == true,
    posterVersion: (j['pv'] as num?)?.toInt() ?? 0,
    at: (j['at'] as num?)?.toDouble() ?? 0,
  );

  final String code;
  final String title;

  /// A movie site's cover (not in the library); '' when it is a library item.
  final String cover;

  /// The library item, while it is in the library.
  final String? item;
  final bool poster;
  final int posterVersion;
  final double at;
}

class Rec {
  Rec(this.j);

  final Map<String, dynamic> j;
  String get code => _s(j['code']);
  String get title => _s(j['title']);
  String get cover => _s(j['cover']);
  double get rating => _d(j['rating']);
  List<String> get reasons => _ls(j['reasons']);
  bool get subMagnet => j['magnet'] == 'sub';
  bool get upcoming => _b(j['upcoming']);
  bool get wished => _b(j['wished']);
}

class Recs {
  Recs(this.j);

  factory Recs.fromJson(Map<String, dynamic> j) => Recs(j);

  final Map<String, dynamic> j;
  List<Rec> get items => [for (final r in (j['items'] as List? ?? [])) if (r is Map) Rec(r.cast<String, dynamic>())];
  bool get running => _b(j['running']);
  double get ts => _d(j['ts']);
  String get error => _s(j['error']);
  Map<String, dynamic> get basis => _m(j['basis']);
}

class Wish {
  Wish(this.j);

  factory Wish.fromJson(Map<String, dynamic> j) => Wish(j);

  final Map<String, dynamic> j;
  String get code => _s(j['code']);
  bool get needSub => _b(j['need_sub']);
  String get status => _s(j['status']);
  String get lastResult => _s(j['last_result']);
  double get lastCheck => _d(j['last_check']);
}

// ---------------- formatting ----------------

String fmtSize(num n) {
  if (n <= 0) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)}${units[i]}';
}

String fmtEta(int s) => s <= 0
    ? ''
    : s > 3600
    ? '${s ~/ 3600}时${s % 3600 ~/ 60}分'
    : s > 60
    ? '${s ~/ 60}分${s % 60}秒'
    : '$s秒';

String fmtAgo(double t, [DateTime? now]) {
  if (t <= 0) return '';
  final d = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - t;
  if (d < 60) return '刚刚';
  if (d < 3600) return '${d ~/ 60} 分钟前';
  if (d < 86400) return '${d ~/ 3600} 小时前';
  return '${d ~/ 86400} 天前';
}

String fmtClock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The home page: recently watched, today's picks from the library, today's
/// recommendations from JavDB.
class Home {
  Home(this.recent, this.picks, this.recs, this.date);

  factory Home.fromJson(Map<String, dynamic> j) => Home(
    parseLibrary(j['recent']),
    parseLibrary(j['picks']),
    [for (final r in (j['recs'] as List? ?? [])) if (r is Map) Rec(r.cast<String, dynamic>())],
    _s(j['date']),
  );

  final List<LibraryItem> recent;
  final List<LibraryItem> picks;
  final List<Rec> recs;
  final String date;
}

/// Seek-bar previews: a sprite sheet of `count` thumbnails, one per `interval` seconds.
class Trickplay {
  Trickplay(this.j);

  final Map<String, dynamic> j;
  String get status => _s(j['status']);
  bool get ready => status == 'ready';
  int get count => _i(j['count']);
  double get interval => _d(j['interval']);
  int get cols => _i(j['cols']);
  int get w => _i(j['w']);
  int get h => _i(j['h']);
  String get sprite => _s(j['sprite']);

  /// Index of the thumbnail for second `t`.
  int indexAt(double t) => interval <= 0 ? 0 : (t / interval).floor().clamp(0, count - 1);
}

/// Where a movie (one part of it) was left, on whichever device: shared through JavHub.
class Progress {
  const Progress({required this.pos, required this.dur, this.done = false, this.part = 0, this.device = '', this.ts = 0});

  factory Progress.fromJson(Map<String, dynamic> j, {int? part}) => Progress(
    pos: _d(j['pos']),
    dur: _d(j['dur']),
    done: _b(j['done']),
    part: part ?? _i(j['part']),
    device: _s(j['device']),
    ts: _d(j['ts']),
  );

  final double pos;
  final double dur;
  final bool done;
  final int part;
  final String device;
  final double ts;

  /// 0-1 for a progress bar (a finished one is full).
  double get fraction => done ? 1 : (dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0);

  /// Worth offering 继续: some way in, not at the end.
  bool get resumable => !done && pos > 30 && (dur <= 0 || pos < dur - 60);
}

/// `/api/progress/{id}`: part -> progress.
Map<int, Progress> parseProgress(Map<String, dynamic> j) {
  final parts = j['parts'];
  if (parts is! Map) return const {};
  return {
    for (final e in parts.entries)
      if (e.value is Map && int.tryParse('${e.key}') != null)
        int.parse('${e.key}'): Progress.fromJson((e.value as Map).cast<String, dynamic>(), part: int.parse('${e.key}')),
  };
}

/// An actress page: her movies in the library and her filmography on JavDB.
class ActorInfo {
  ActorInfo(this.j)
    : items = [for (final x in (j['items'] as List? ?? const [])) LibraryItem.fromJson(_m(x))],
      works = [for (final x in (j['works'] as List? ?? const [])) ActorWork(_m(x))];

  final Map<String, dynamic> j;
  final List<LibraryItem> items;
  final List<ActorWork> works;
  String get name => _s(j['name']);
  String get jname => _s(j['jname']);
  String get aid => _s(j['aid']);
  bool get followed => _b(j['followed']);
  double get updated => _d(j['updated']);
  String get error => _s(j['error']);
  String get note => _s(j['note']);
}

class ActorWork {
  ActorWork(this.j);

  final Map<String, dynamic> j;
  String get code => _s(j['code']);
  String get title => _s(j['title']);
  String get cover => _s(j['cover']);
  String get date => _s(j['date']);
  double get rating => _d(j['rating']);
  String get magnet => _s(j['magnet']);
  String? get inLibrary => j['in_library'] == null ? null : _s(j['in_library']);
  bool get wished => _b(j['wished']);
}
