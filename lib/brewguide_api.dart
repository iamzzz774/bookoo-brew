import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'mt80.dart';

/// brew-guide 的 Supabase REST 客户端。
/// 行结构/字段与 brew-guide app、gaggiuino_to_brewguide.py 完全一致，确保 app 实时同步能认。
class BrewGuideApi {
  static const Duration requestTimeout = Duration(seconds: 15);

  final String baseUrl; // https://<project>.supabase.co
  final String key; // anon / publishable key
  final String userId;
  final http.Client? _client;
  BrewGuideApi({
    required this.baseUrl,
    required this.key,
    required this.userId,
    http.Client? client,
  }) : _client = client;

  Map<String, String> get _headers => {
    'apikey': key,
    'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
  };

  String get _rest => '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/rest/v1';

  Uri _beanUri(String table, Map<String, String> query) {
    final base = Uri.parse('$_rest/$table');
    if (base.scheme != 'https' || base.userInfo.isNotEmpty) {
      throw const FormatException('同步需要 HTTPS 地址');
    }
    return base.replace(
      queryParameters: {
        ...query,
        'user_id': 'eq.$userId',
        'deleted_at': 'is.null',
      },
    );
  }

  Future<List<Map<String, dynamic>>> _beanRows(
    String table,
    Map<String, String> query,
  ) async {
    final uri = _beanUri(table, query);
    final response =
        await (_client?.get(uri, headers: _headers) ??
                http.get(uri, headers: _headers))
            .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw Exception('读取咖啡豆失败（${response.statusCode}）');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List || decoded.any((row) => row is! Map)) {
      throw const FormatException('咖啡豆数据不完整');
    }
    return decoded.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<Map<String, dynamic>> _freshBean(String beanId) async {
    final rows = await _beanRows('coffee_beans', {
      'id': 'eq.$beanId',
      'select': 'id,user_id,data,updated_at',
      'limit': '2',
    });
    if (rows.length != 1 ||
        rows.single['id'] != beanId ||
        rows.single['user_id'] != userId ||
        rows.single['data'] is! Map ||
        rows.single['updated_at'] is! String) {
      throw const FormatException('咖啡豆记录不存在或已变化');
    }
    return rows.single;
  }

  /// 取前导数字：'200'/'10.0'/'18g' → double（与 brew-guide parseGrams 一致）。
  static double parseGrams(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is! String) return 0.0;
    final m = RegExp(r'^\s*([\d.]+)').firstMatch(v);
    return m == null ? 0.0 : (double.tryParse(m.group(1)!) ?? 0.0);
  }

  static String numStr(double x) {
    var s = x.toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s.isEmpty ? '0' : s;
  }

  /// 列出在用的手冲豆（beanType=filter 且 remaining>0），按烘焙日期从早到晚。
  Future<List<Bean>> listFilterBeans() async {
    final lightUrl =
        '$_rest/coffee_beans?deleted_at=is.null&user_id=eq.$userId'
        '&select=id,data&order=updated_at.desc&limit=80';
    final resp = await http
        .get(Uri.parse(lightUrl), headers: _headers)
        .timeout(requestTimeout);
    if (resp.statusCode >= 300) {
      throw Exception('查询豆子失败 HTTP ${resp.statusCode}: ${resp.body}');
    }
    final rows = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
    final beans = <Bean>[];
    for (final row in rows) {
      final data = (row['data'] as Map?)?.cast<String, dynamic>() ?? {};
      if (data['beanType'] != 'filter') continue;
      final remaining = parseGrams(data['remaining']);
      if (remaining <= 0) continue;
      beans.add(
        Bean(
          id: row['id'].toString(),
          name: (data['name'] ?? '').toString(),
          roastLevel: (data['roastLevel'] ?? '').toString(),
          roaster: data['roaster']?.toString(),
          roastDate: data['roastDate']?.toString(),
          process: _extractProcess(data),
          remaining: remaining,
          raw: data,
        ),
      );
    }
    sortBeansForDisplay(beans);
    return beans;
  }

  /// 按烘焙日期从早到晚排序；空日期、"在途"、非日期值排最后。
  static void sortBeansForDisplay(List<Bean> beans) {
    beans.sort((a, b) {
      final da = _parseRoastDate(a.roastDate);
      final db = _parseRoastDate(b.roastDate);
      if (da == null && db == null) return a.name.compareTo(b.name);
      if (da == null) return 1;
      if (db == null) return -1;
      final dateCompare = da.compareTo(db);
      return dateCompare != 0 ? dateCompare : a.name.compareTo(b.name);
    });
  }

  static DateTime? _parseRoastDate(String? value) {
    final s = value?.trim();
    if (s == null || s.isEmpty || s == '在途') return null;
    final normalized = s.replaceAll('/', '-');
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(normalized);
    if (m == null) return null;
    final year = m.group(1)!;
    final month = m.group(2)!.padLeft(2, '0');
    final day = m.group(3)!.padLeft(2, '0');
    return DateTime.tryParse('$year-$month-$day');
  }

  /// 提取处理法：优先 blendComponents[0].process，退到顶层 process。
  static String? _extractProcess(Map<String, dynamic> data) {
    final bc = data['blendComponents'];
    if (bc is List && bc.isNotEmpty && bc.first is Map) {
      final p = (bc.first as Map)['process'];
      if (p is String && p.trim().isNotEmpty) return p.trim();
    }
    final top = data['process'];
    if (top is String && top.trim().isNotEmpty) return top.trim();
    return null;
  }

  /// upsert 一条手冲笔记到 brewing_notes。幂等（note['id'] 确定性）。
  Future<void> pushNote(Map<String, dynamic> note) async {
    final row = {
      'id': note['id'],
      'user_id': userId,
      'data': note,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'deleted_at': null,
    };
    final resp = await http
        .post(
          Uri.parse('$_rest/brewing_notes'),
          headers: {
            ..._headers,
            'Prefer': 'resolution=merge-duplicates,return=representation',
          },
          body: utf8.encode(jsonEncode(row)),
        )
        .timeout(requestTimeout);
    if (resp.statusCode >= 300) {
      throw Exception('写笔记失败 HTTP ${resp.statusCode}: ${resp.body}');
    }
  }

  /// 读已存在笔记的 data（用于扣库存幂等判断）。
  Future<Map<String, dynamic>?> getNoteData(String noteId) async {
    final url =
        '$_rest/brewing_notes?id=eq.$noteId&user_id=eq.$userId&select=data';
    final resp = await http
        .get(Uri.parse(url), headers: _headers)
        .timeout(requestTimeout);
    if (resp.statusCode >= 300) {
      throw Exception('查询已有笔记失败 HTTP ${resp.statusCode}: ${resp.body}');
    }
    final rows = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
    if (rows.isEmpty) return null;
    return (rows.first['data'] as Map?)?.cast<String, dynamic>();
  }

  Future<List<dynamic>> _mt80Rows(Map<String, String> filters) async {
    final uri = Uri.parse('$_rest/brewing_notes').replace(
      queryParameters: {
        'user_id': 'eq.$userId',
        'deleted_at': 'is.null',
        'select': 'id,data,updated_at',
        ...filters,
      },
    );
    final response =
        await (_client?.get(uri, headers: _headers) ??
                http.get(uri, headers: _headers))
            .timeout(requestTimeout);
    if (response.statusCode >= 300) {
      throw Exception('读取 MT80 记录失败（${response.statusCode}）');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as List;
  }

  /// Resume a genuine pending hand-brew request after an app restart.
  Future<Map<String, dynamic>?> pendingMt80Note() async {
    final rows = await _mt80Rows({
      'id': 'like.bookoo-*',
      'data->mt80Request->>schemaVersion': 'eq.1',
      'data->mt80Request->>status': 'in.(pending,needs_confirmation)',
      'order': 'updated_at.desc',
      'limit': '1',
    });
    if (rows.isEmpty) return null;
    return (rows.first['data'] as Map).cast<String, dynamic>();
  }

  /// Selection changes only the grind request, using a compare-and-swap so
  /// concurrent Mac enrichment or user edits cannot be overwritten.
  Future<void> selectMt80Event(String noteId, String eventId) async {
    if (!noteId.startsWith('bookoo-')) throw Exception('不是手冲记录');
    final rows = await _mt80Rows({'id': 'eq.$noteId', 'limit': '1'});
    if (rows.isEmpty) throw Exception('记录已不存在');
    final row = rows.single as Map;
    final data = Map<String, dynamic>.from(row['data'] as Map);
    final result = Mt80Result.fromNote(data);
    if (result.status != 'needs_confirmation' ||
        !result.candidates.any((c) => c.eventId == eventId)) {
      throw Exception('磨豆记录已变化，请刷新后重试');
    }
    final request = Map<String, dynamic>.from(data['mt80Request'] as Map);
    request['status'] = 'pending';
    request['selectedEventId'] = eventId;
    data['mt80Request'] = request;
    final revision = row['updated_at'];
    if (revision is! String || revision.isEmpty) throw Exception('记录版本无效');
    final uri = Uri.parse('$_rest/brewing_notes').replace(
      queryParameters: {
        'id': 'eq.$noteId',
        'user_id': 'eq.$userId',
        'deleted_at': 'is.null',
        'updated_at': 'eq.$revision',
      },
    );
    final headers = {..._headers, 'Prefer': 'return=representation'};
    final body = utf8.encode(
      jsonEncode({
        'data': data,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    final response =
        await (_client?.patch(uri, headers: headers, body: body) ??
                http.patch(uri, headers: headers, body: body))
            .timeout(requestTimeout);
    if (response.statusCode >= 300) {
      throw Exception('确认磨豆记录失败（${response.statusCode}）');
    }
    final written = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    if (written.length != 1 ||
        written.single['id'] != noteId ||
        written.single['data']['mt80Request']['selectedEventId'] != eventId) {
      throw Exception('记录已变化，请刷新后重试');
    }
    final verified = await _mt80Rows({'id': 'eq.$noteId', 'limit': '1'});
    if (verified.length != 1 ||
        verified.single['data']['mt80Request']['selectedEventId'] != eventId) {
      throw Exception('尚未核验本次选择，请刷新后确认');
    }
  }

  /// Fresh row + CAS preserves pending preset requests and concurrent bean edits.
  Future<(double, double)> deductBean(Bean bean, double dose) async {
    if (!dose.isFinite || dose <= 0) throw const FormatException('粉量无效');
    final current = await _freshBean(bean.id);
    final data = Map<String, dynamic>.from(current['data'] as Map);
    final old = parseGrams(data['remaining']);
    final neu = (old - dose) < 0 ? 0.0 : (old - dose);
    data['remaining'] = numStr(neu);
    final uri = _beanUri('coffee_beans', {
      'id': 'eq.${bean.id}',
      'updated_at': 'eq.${current['updated_at']}',
    });
    final headers = {..._headers, 'Prefer': 'return=representation'};
    final body = utf8.encode(
      jsonEncode({
        'data': data,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    final response =
        await (_client?.patch(uri, headers: headers, body: body) ??
                http.patch(uri, headers: headers, body: body))
            .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw Exception('扣库存未完成（${response.statusCode}），请先核对，勿重复提交');
    }
    final rows = jsonDecode(utf8.decode(response.bodyBytes));
    if (rows is! List ||
        rows.length != 1 ||
        rows.single['id'] != bean.id ||
        rows.single['data'] is! Map ||
        parseGrams(rows.single['data']['remaining']) != neu) {
      throw const FormatException('库存记录已变化，请先核对后重试');
    }
    return (old, neu);
  }
}
