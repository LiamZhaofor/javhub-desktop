import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

const defaultServer = 'https://javhub.liamzhao.codes';

class ApiError implements Exception {
  ApiError(this.message, {this.status});

  final String message;
  final int? status;

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

/// The JavHub web API, as the browser uses it: a session cookie from /api/login,
/// JSON everywhere, the library list with an ETag.
class JavHubApi {
  JavHubApi({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  String server = defaultServer;
  String? _token;
  String user = '';

  /// The client runs on the same network as the NAS (no 115 limits to dodge there).
  bool lan = false;

  /// Called when the server says the session is gone.
  void Function()? onUnauthorized;

  static const _prefServer = 'javhub.server';
  static const _prefToken = 'javhub.token';
  static const _prefUser = 'javhub.user';

  Map<String, String> get authHeaders => _token == null ? const {} : {'Cookie': 'jh=$_token'};
  bool get loggedIn => _token != null;

  Uri uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(server.endsWith('/') ? server.substring(0, server.length - 1) : server);
    final p = Uri.parse(path);
    return base.replace(
      path: '${base.path}${p.path}',
      queryParameters: {...p.queryParameters, ...?query}.isEmpty ? null : {...p.queryParameters, ...?query},
    );
  }

  String url(String path, [Map<String, String>? query]) => uri(path, query).toString();

  /// A file of a library item, e.g. its poster (`?w=` asks for a small JPEG).
  String media(String id, String file, {int? width, int? version}) => url(
    '/media/${Uri.encodeComponent(id)}/${Uri.encodeComponent(file)}',
    {if (width != null) 'w': '$width', if (version != null && version > 0) 'v': '$version'},
  );

  /// A picture from a movie site, through JavHub (they check the referer).
  String image(String remote) => url('/api/img', {'u': remote});

  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    server = p.getString(_prefServer) ?? defaultServer;
    _token = p.getString(_prefToken);
    user = p.getString(_prefUser) ?? '';
  }

  Future<void> login(String serverUrl, String name, String password) async {
    server = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final r = await _http
        .post(uri('/api/login'), headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user': name, 'password': password}))
        .timeout(const Duration(seconds: 20));
    final body = _decode(r);
    if (r.statusCode != 200) throw ApiError(body['error']?.toString() ?? 'HTTP ${r.statusCode}', status: r.statusCode);
    final cookie = r.headers['set-cookie'] ?? '';
    final m = RegExp(r'jh=([^;]+)').firstMatch(cookie);
    if (m == null) throw ApiError('服务器没有返回登录凭据');
    _token = m[1];
    user = name;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefServer, server);
    await p.setString(_prefToken, _token!);
    await p.setString(_prefUser, user);
  }

  Future<void> logout() async {
    try {
      await post('/api/logout');
    } catch (_) {}
    _token = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefToken);
  }

  /// Checks the stored session; false when it has to log in again.
  Future<bool> me() async {
    if (_token == null) return false;
    try {
      final d = await get('/api/me');
      lan = d['lan'] == true;
      return d['user'] != null;
    } on ApiError catch (e) {
      if (e.unauthorized) return false;
      rethrow;
    }
  }

  Map<String, dynamic> _decode(http.Response r) {
    try {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      return d is Map<String, dynamic> ? d : {'data': d};
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call) async {
    final http.Response r;
    try {
      r = await call().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw ApiError('连接 JavHub 超时');
    } on SocketException catch (e) {
      throw ApiError('无法连接 JavHub: ${e.message}');
    } on http.ClientException catch (e) {
      throw ApiError('无法连接 JavHub: ${e.message}');
    }
    final body = _decode(r);
    if (r.statusCode == 401) {
      onUnauthorized?.call();
      throw ApiError('请先登录', status: 401);
    }
    if (r.statusCode >= 400) throw ApiError(body['error']?.toString() ?? 'HTTP ${r.statusCode}', status: r.statusCode);
    return body;
  }

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _send(() => _http.get(uri(path, query), headers: authHeaders));

  Future<Map<String, dynamic>> post(String path, [Object? body]) => _send(() => _http.post(uri(path),
      headers: {...authHeaders, 'Content-Type': 'application/json'}, body: body == null ? null : jsonEncode(body)));

  Future<Map<String, dynamic>> delete(String path) => _send(() => _http.delete(uri(path), headers: authHeaders));

  // ---------------- library ----------------

  /// The library list. Kept on disk with its ETag: the list only crosses the
  /// (slow) home uplink again when it changed.
  Future<List<LibraryItem>> library({bool rescan = false, void Function(List<LibraryItem>)? cached}) async {
    final file = await _cacheFile('library.json');
    Map<String, dynamic>? saved;
    try {
      if (!rescan && await file.exists()) saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    final savedItems = saved == null ? null : parseLibrary(saved['items']);
    if (savedItems != null && cached != null) cached(savedItems);
    final headers = {...authHeaders, if (savedItems != null && saved?['etag'] != null) 'If-None-Match': saved!['etag'] as String};
    final r = await _http
        .get(uri('/api/library', rescan ? {'rescan': '1'} : null), headers: headers)
        .timeout(const Duration(seconds: 90));
    if (r.statusCode == 304 && savedItems != null) return savedItems;
    if (r.statusCode == 401) {
      onUnauthorized?.call();
      throw ApiError('请先登录', status: 401);
    }
    final body = _decode(r);
    if (r.statusCode != 200) throw ApiError(body['error']?.toString() ?? 'HTTP ${r.statusCode}');
    try {
      await file.writeAsString(jsonEncode({'etag': r.headers['etag'], 'items': body['items']}));
    } catch (_) {}
    return parseLibrary(body['items']);
  }

  Future<LibraryItem> libraryItem(String id) async =>
      LibraryItem.fromJson(await get('/api/library/${Uri.encodeComponent(id)}'));

  Future<File> _cacheFile(String name) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}cache');
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  // ---------------- search / download ----------------

  Future<SearchResult> search(String code, {String subtitle = '', bool refresh = false}) async =>
      SearchResult.fromJson(await get('/api/search', {
        'code': code,
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        if (refresh) 'refresh': '1',
      }));

  Future<Backends> backends() async => Backends.fromJson(await get('/api/backends'));

  Future<Job> createJob(String code, {String? magnet, required String backend, bool replace = false, String subtitle = ''}) async {
    final d = await post('/api/jobs', {
      'code': code,
      if (magnet != null) 'magnet': magnet,
      'backend': backend,
      'replace': replace,
      if (subtitle.isNotEmpty) 'subtitle': subtitle,
    });
    return Job.fromJson(d['job'] as Map<String, dynamic>);
  }

  Future<List<Job>> jobs() async =>
      ((await get('/api/jobs', {'limit': '80'}))['jobs'] as List? ?? []).map((j) => Job.fromJson(j as Map<String, dynamic>)).toList();

  Future<void> cancelJob(String id) => post('/api/jobs/$id/cancel');
  Future<void> retryJob(String id) => post('/api/jobs/$id/retry');
  Future<void> deleteJob(String id) => delete('/api/jobs/$id');

  // ---------------- recommendations / wishlist ----------------

  Future<Recs> recs({bool refresh = false}) async =>
      Recs.fromJson(refresh ? await post('/api/recs/refresh') : await get('/api/recs'));

  Future<List<Wish>> wishlist() async =>
      ((await get('/api/wishlist'))['items'] as List? ?? []).map((w) => Wish.fromJson(w as Map<String, dynamic>)).toList();

  Future<void> addWish(String code, {bool needSub = false}) => post('/api/wishlist', {'code': code, 'need_sub': needSub});
  Future<void> removeWish(String code) => delete('/api/wishlist/${Uri.encodeComponent(code)}');
  Future<void> checkWish(String code) => post('/api/wishlist/${Uri.encodeComponent(code)}/check');
}
