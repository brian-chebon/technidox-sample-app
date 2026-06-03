// TechniDox end-to-end smoke CLI. Authenticates via Firebase (like DartStream),
// then hits a representative endpoint per surface against the live API and
// prints PASS / FAIL / SKIP.
//
//   cp .env.example .env   # fill FIREBASE_API_KEY + TEST_EMAIL/TEST_PASSWORD
//   set -a && source .env && set +a
//   dart pub get
//   dart run bin/smoke.dart
//
// The unauthenticated /health check always runs. Without FIREBASE_API_KEY (or
// test creds) every authenticated step is SKIPPED (not failed).

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

  print('== TechniDox E2E smoke ==');
  print('  base     : $base');
  print('  auth     : ${canAuth ? 'Firebase ($email)' : 'MISSING key/creds (authed steps SKIP)'}');
  print('');

  // 1. health (unauthenticated)
  await _step('GET  /health', 'health', () => http.get(Uri.parse('$base/health')));

  // Firebase sign-in -> idToken (gates every authed step)
  String? idToken;
  if (canAuth) {
    idToken = await _firebaseAuth(apiKey, email, password);
  }
  if (idToken == null) {
    for (final s in const [
      ['POST /api/v1/auth/login (signup fallback)', 'auth'],
      ['GET  /api/v1/me', 'users'],
      ['GET  /api/v1/technidox/dashboard/stats', 'technidox'],
      ['GET  /api/v1/billing/subscription', 'billing'],
    ]) {
      _skip(s[1], s[0]);
    }
    _summary();
    exit(_results.any((r) => r.pass == false) ? 1 : 0);
  }

  // 2. auth: onboard / sign in with the verified idToken (login, signup fallback)
  await _step('POST /api/v1/auth/login (signup fallback)', 'auth',
      () => _onboard(base, idToken!),
      allow: const [200, 201], onBody: (b) {
    final t = _extractTenant(b);
    if (t != null) tenant = t;
  });

  final auth = {'authorization': 'Bearer $idToken', 'x-tenant-id': tenant};

  // 3. users: current identity
  await _step('GET  /api/v1/me', 'users',
      () => http.get(Uri.parse('$base/api/v1/me'), headers: auth));

  // 4. technidox product: dashboard stats
  await _step('GET  /api/v1/technidox/dashboard/stats', 'technidox',
      () => http.get(Uri.parse('$base/api/v1/technidox/dashboard/stats'),
          headers: auth));

  // 5. billing: subscription
  await _step('GET  /api/v1/billing/subscription', 'billing',
      () => http.get(Uri.parse('$base/api/v1/billing/subscription'),
          headers: auth));

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

/// Onboard the verified identity: try /login, fall back to /signup for a
/// first-run user that isn't onboarded yet. Returns whichever succeeded.
Future<http.Response> _onboard(String base, String idToken) async {
  final body = jsonEncode({'idToken': idToken});
  const h = {'content-type': 'application/json'};
  final login =
      await http.post(Uri.parse('$base/api/v1/auth/login'), headers: h, body: body);
  if (login.statusCode == 200 || login.statusCode == 201) return login;
  final signup =
      await http.post(Uri.parse('$base/api/v1/auth/signup'), headers: h, body: body);
  return (signup.statusCode == 200 || signup.statusCode == 201) ? signup : login;
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
  _results.add(_Result('auth', 'Firebase sign-in', false,
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
  print('\n== Summary ==');
  final pass = _results.where((r) => r.pass == true).length;
  final fail = _results.where((r) => r.pass == false).length;
  final skip = _results.where((r) => r.pass == null).length;
  for (final r in _results) {
    final tag = r.pass == null ? 'SKIP' : (r.pass! ? 'PASS' : 'FAIL');
    final st = r.status != null ? ' (${r.status})' : '';
    final nt = r.note != null ? '  — ${r.note}' : '';
    print('  [$tag] ${r.group.padRight(10)} ${r.label}$st$nt');
  }
  print('\n  $pass pass, $fail fail, $skip skip');
}
