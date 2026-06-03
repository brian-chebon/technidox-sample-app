// TechniDox doc-product deep-dive: exercises the customer documentation product
// surface (`/api/v1/technidox`) against the live API and prints PASS/FAIL/SKIP.
//
// The product API is currently the workspace `/overview` endpoint (Phase 1 is
// not yet wired to the planned documentation_* tables), so this deep-dive does
// a thorough *contract* check of the overview response: doc health score,
// health breakdown, release policy, planned tables, and phase-one capabilities.
//
//   set -a && source .env && set +a
//   dart run bin/technidox_deepdive.dart
//
// /health runs unauthenticated. Without FIREBASE_API_KEY + test creds every
// authenticated step is SKIPPED (not failed).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _firebaseSignIn =
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword';
const _firebaseSignUp =
    'https://identitytoolkit.googleapis.com/v1/accounts:signUp';

final List<_Result> _results = [];

void main(List<String> args) async {
  final env = Platform.environment;
  final base = _get(env, 'TECHNIDOX_API_BASE_URL', 'https://dev-api.technidox.dev');
  final apiKey = env['FIREBASE_API_KEY']?.trim() ?? '';
  final email = env['TEST_EMAIL']?.trim() ?? '';
  final password = env['TEST_PASSWORD']?.trim() ?? '';
  var tenant = _get(env, 'TECHNIDOX_TENANT_ID', 'default');
  final canAuth = apiKey.isNotEmpty && email.isNotEmpty && password.isNotEmpty;

  print('== TechniDox doc-product deep-dive ==');
  print('  base : $base');
  print('  auth : ${canAuth ? 'Firebase ($email)' : 'MISSING key/creds (authed steps SKIP)'}');
  print('');

  await _step('GET  /health', 'health', () => http.get(Uri.parse('$base/health')));

  String? idToken;
  if (canAuth) idToken = await _firebaseAuth(apiKey, email, password);

  // Contract-check labels exercised against the /overview body.
  const checks = [
    ['overview', 'body: success == true'],
    ['overview', 'body: product.name == "TechniDox"'],
    ['overview', 'body: summary.docHealthScore is a number'],
    ['overview', 'body: summary.minimumGateScore present'],
    ['overview', 'body: healthBreakdown is a non-empty list'],
    ['overview', 'body: releasePolicy.minimumQualityScore present'],
    ['overview', 'body: databaseTarget.plannedTables is a non-empty list'],
    ['overview', 'body: phaseOne is a non-empty list'],
  ];

  if (idToken == null) {
    _skip('product', 'POST /api/v1/auth/login (bootstrap)');
    _skip('product', 'GET  /api/v1/technidox/overview');
    for (final c in checks) {
      _skip(c[0], c[1]);
    }
    _summary();
    exit(_results.any((r) => r.pass == false) ? 1 : 0);
  }

  // bootstrap tenant
  await _step('POST /api/v1/auth/login (bootstrap)', 'product', () {
    return http.post(Uri.parse('$base/api/v1/auth/login'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'idToken': idToken}));
  }, allow: const [200, 201], onBody: (b) {
    final t = _extractTenant(b);
    if (t != null) tenant = t;
  });

  final auth = {'authorization': 'Bearer $idToken', 'x-tenant-id': tenant};

  String? overviewBody;
  await _step('GET  /api/v1/technidox/overview', 'product', () {
    return http.get(Uri.parse('$base/api/v1/technidox/overview'), headers: auth);
  }, onBody: (b) => overviewBody = b);

  // ---- contract checks on the overview body ----
  if (overviewBody == null) {
    for (final c in checks) {
      _skip(c[0], c[1]);
    }
  } else {
    Map<String, dynamic>? root;
    Map<String, dynamic>? data;
    try {
      root = jsonDecode(overviewBody!) as Map<String, dynamic>;
      data = root['data'] as Map<String, dynamic>?;
    } catch (_) {}
    final product = data?['product'] as Map?;
    final summary = data?['summary'] as Map?;
    final policy = data?['releasePolicy'] as Map?;
    final dbTarget = data?['databaseTarget'] as Map?;

    _check('overview', 'body: success == true', root?['success'] == true);
    _check('overview', 'body: product.name == "TechniDox"',
        product?['name'] == 'TechniDox');
    _check('overview', 'body: summary.docHealthScore is a number',
        summary?['docHealthScore'] is num);
    _check('overview', 'body: summary.minimumGateScore present',
        summary?['minimumGateScore'] != null);
    _check('overview', 'body: healthBreakdown is a non-empty list',
        data?['healthBreakdown'] is List &&
            (data!['healthBreakdown'] as List).isNotEmpty);
    _check('overview', 'body: releasePolicy.minimumQualityScore present',
        policy?['minimumQualityScore'] != null);
    _check('overview', 'body: databaseTarget.plannedTables is a non-empty list',
        dbTarget?['plannedTables'] is List &&
            (dbTarget!['plannedTables'] as List).isNotEmpty);
    _check('overview', 'body: phaseOne is a non-empty list',
        data?['phaseOne'] is List && (data!['phaseOne'] as List).isNotEmpty);
  }

  _summary();
  exit(_results.any((r) => r.pass == false) ? 1 : 0);
}

// ---------------------------------------------------------------------------

class _Result {
  _Result(this.group, this.label, this.pass, {this.status, this.note});
  final String group;
  final String label;
  final bool? pass;
  final int? status;
  final String? note;
}

void _skip(String group, String label) {
  print('-- $label --\n   [SKIP] no Firebase key/creds');
  _results.add(_Result(group, label, null, note: 'no auth'));
}

void _check(String group, String label, bool pass) {
  print('-- check: $label --\n   ${pass ? '[PASS]' : '[FAIL]'}');
  _results.add(_Result(group, label, pass));
}

Future<void> _step(
  String label,
  String group,
  Future<http.Response> Function() send, {
  List<int> allow = const [200],
  void Function(String body)? onBody,
}) async {
  print('-- $label --');
  try {
    final sw = Stopwatch()..start();
    final resp = await send().timeout(const Duration(seconds: 30));
    sw.stop();
    final ok = allow.contains(resp.statusCode);
    final ex = _excerpt(resp.body);
    print('   ${ok ? '[PASS]' : '[FAIL]'} -> ${resp.statusCode} in ${sw.elapsedMilliseconds}ms');
    if (ex.isNotEmpty) print('   body: $ex');
    _results.add(_Result(group, label, ok, status: resp.statusCode));
    if (ok) onBody?.call(resp.body);
  } on TimeoutException {
    print('   [FAIL] TIMEOUT');
    _results.add(_Result(group, label, false, note: 'timeout'));
  } catch (e) {
    print('   [FAIL] $e');
    _results.add(_Result(group, label, false, note: '$e'));
  }
}

String? _extractTenant(String body) {
  try {
    final d = jsonDecode(body);
    if (d is! Map) return null;
    final user = (d['data'] is Map ? d['data']['user'] : null) ?? d['user'] ?? d;
    for (final m in [user, d]) {
      if (m is Map) {
        for (final k in ['tenant_id', 'tenantId', 'active_tenant_id', 'activeTenantId']) {
          final v = m[k];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> _firebaseAuth(String apiKey, String email, String pw) async {
  print('-- Firebase sign-in --');
  final body = jsonEncode({'email': email, 'password': pw, 'returnSecureToken': true});
  final headers = {
    'content-type': 'application/json',
    'referer': Platform.environment['FIREBASE_REFERER'] ?? 'http://localhost:3000',
  };
  final si = await http.post(Uri.parse('$_firebaseSignIn?key=$apiKey'), headers: headers, body: body);
  if (si.statusCode == 200) {
    final t = (jsonDecode(si.body) as Map)['idToken'] as String?;
    if (t != null) {
      print('   [PASS] signIn -> idToken');
      return t;
    }
  }
  print('   signIn ${si.statusCode}; trying signUp');
  final su = await http.post(Uri.parse('$_firebaseSignUp?key=$apiKey'), headers: headers, body: body);
  if (su.statusCode == 200) {
    final t = (jsonDecode(su.body) as Map)['idToken'] as String?;
    if (t != null) {
      print('   [PASS] signUp -> idToken');
      return t;
    }
  }
  print('   [FAIL] Firebase auth: signIn=${si.statusCode} signUp=${su.statusCode}');
  _results.add(_Result('product', 'Firebase sign-in', false,
      note: 'signIn=${si.statusCode} signUp=${su.statusCode}'));
  return null;
}

String _get(Map<String, String> env, String k, String fallback) =>
    (env[k]?.trim().isNotEmpty ?? false) ? env[k]!.trim() : fallback;

String _excerpt(String body) {
  final t = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return '';
  return t.length > 240 ? '${t.substring(0, 240)}...' : t;
}

void _summary() {
  print('\n== Doc-product deep-dive summary ==');
  final pass = _results.where((r) => r.pass == true).length;
  final fail = _results.where((r) => r.pass == false).length;
  final skip = _results.where((r) => r.pass == null).length;
  for (final r in _results) {
    final tag = r.pass == null ? 'SKIP' : (r.pass! ? 'PASS' : 'FAIL');
    final st = r.status != null ? ' (${r.status})' : '';
    final nt = r.note != null ? '  — ${r.note}' : '';
    print('  [$tag] ${r.group.padRight(8)} ${r.label}$st$nt');
  }
  print('\n  $pass pass, $fail fail, $skip skip');
  if (skip > 0) {
    print('  (set FIREBASE_API_KEY + TEST_EMAIL/TEST_PASSWORD in .env to run authed steps)');
  }
}
