import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'gemini_key_service.dart';

/// On a TV: a small web page, served by the TV itself on the home network
/// while its Gemini key screen is open (see GeminiKeyFromPhone), where the
/// viewer gets their key from Google and pastes it — on their phone, since
/// typing a key that long with a remote is a chore. The page is at a
/// random address that only works until the screen closes; nothing goes
/// further than the network but the key's check with Google
/// (GeminiKeyService.test).
class PhoneKeyServer {
  PhoneKeyServer({
    required this.onKey,
    this.onOpened,
    this.onChecking,
    this.onProblem,
  });

  /// A key that works came from the phone, and is saved.
  final void Function() onKey;

  /// The page was opened on the phone.
  final void Function()? onOpened;

  /// A key came from the phone and is being checked.
  final void Function()? onChecking;

  /// The key from the phone didn't work: why, as the phone is told too.
  final void Function(String problem)? onProblem;

  HttpServer? _server;
  bool _checking = false;

  // Easy to type from the screen if scanning fails: no 0/o, 1/l/i.
  static const _letters = 'abcdefghjkmnpqrstuvwxyz23456789';
  final String _token = String.fromCharCodes(Iterable.generate(
      8,
      (_) => _letters.codeUnitAt(Random.secure().nextInt(_letters.length))));

  static const _preferredPort = 8686;

  /// Starts it: the page's address, or null when the TV isn't on a
  /// network.
  Future<String?> start() async {
    final ip = await _localAddress();
    if (ip == null) return null;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _preferredPort);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle, onError: (_) {});
    return 'http://$ip:${_server!.port}/$_token';
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var saved = false;
    try {
      if (request.uri.path != '/$_token') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method == 'GET') {
        response.headers.contentType = ContentType.html;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(_page);
        onOpened?.call();
        return;
      }
      if (request.method != 'POST' || _checking) {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      // A key is a few dozen characters: anything much bigger isn't one.
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > 4096) break;
      }
      var key = '';
      try {
        key = ((jsonDecode(utf8.decode(bytes)) as Map)['key'] ?? '')
            .toString()
            .trim();
      } catch (_) {}
      _checking = true;
      onChecking?.call();
      final problem = await GeminiKeyService.test(key);
      _checking = false;
      response.headers.contentType = ContentType.json;
      if (problem == null) {
        await GeminiKeyService().save(key);
        saved = true;
        response.write(jsonEncode({'ok': true}));
      } else {
        onProblem?.call(problem);
        response.write(jsonEncode({'ok': false, 'error': problem}));
      }
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } catch (_) {}
      // After the phone's been answered: this may close the screen, and
      // with it the server.
      if (saved) onKey();
    }
  }

  /// The TV's address on the home network: Wi-Fi's or the cable's first.
  static Future<String?> _localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? any;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.isLinkLocal) continue;
          final name = interface.name;
          if (name.startsWith('wlan') || name.startsWith('eth')) {
            return address.address;
          }
          any ??= address.address;
        }
      }
      return any;
    } catch (_) {
      return null;
    }
  }

  // The phone's page: the same steps as the app's own key form
  // (GeminiKeyForm), a paste box, and Send to TV.
  static const _page = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Popcorn: add your Gemini key</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #000; color: #fff;
    font: 16px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  main { max-width: 480px; margin: 0 auto; padding: 28px 16px 40px; }
  .brand { color: #FDEDAD; font-weight: 700; letter-spacing: .2px; margin: 0 0 4px; }
  h1 { font-size: 24px; margin: 0 0 10px; }
  p, li { color: rgba(255,255,255,.72); }
  b { color: #fff; font-weight: 600; }
  ol { padding-left: 20px; margin: 14px 0 20px; }
  li { margin: 6px 0; }
  .button {
    display: block; width: 100%; padding: 14px 16px; border: 0;
    border-radius: 14px; font: inherit; font-weight: 700; text-align: center;
    text-decoration: none; cursor: pointer;
  }
  .primary { background: #FDEDAD; color: #000; }
  .secondary { background: rgba(255,255,255,.1); color: #fff; }
  input {
    width: 100%; padding: 14px; margin: 0 0 10px; border: 0; border-radius: 12px;
    background: rgba(255,255,255,.08); color: #fff; font: inherit;
  }
  #status { min-height: 1.4em; margin: 12px 0 0; }
  .error { color: #FF8A80; }
  .done { color: #A5D6A7; font-weight: 600; }
  small { display: block; margin-top: 22px; color: rgba(255,255,255,.4); font-size: 13px; }
</style>
</head>
<body>
<main>
  <p class="brand">Popcorn</p>
  <h1>Add your Gemini key</h1>
  <p>A free code from Google that lets Popcorn on your TV answer your
  questions in Ask and make Sinhala subtitles. It costs nothing, and you
  only do this once.</p>
  <a class="button secondary" href="https://aistudio.google.com/app/apikey"
     target="_blank" rel="noopener">Get my key</a>
  <ol>
    <li>Tap <b>Get my key</b> above. Google&rsquo;s page opens: sign in with
    your Google (Gmail) account if it asks.</li>
    <li>Tap <b>Create API key</b>.</li>
    <li>If it asks you to choose a project, tap that box and pick
    <b>Create project</b>, give it any name, for example <b>&ldquo;Popcorn&rdquo;</b>,
    and tap <b>Create</b>. Then tap <b>Create key</b>.</li>
    <li>Copy your new key (a long code starting with <b>AIza</b>), come
    back to this page, paste it below and tap <b>Send to TV</b>.</li>
  </ol>
  <form id="form">
    <input id="key" autocomplete="off" autocapitalize="off" spellcheck="false"
           placeholder="Paste your key">
    <button class="button primary" id="send" type="submit">Send to TV</button>
  </form>
  <p id="status"></p>
  <small>Kept only on your TV. On the free plan, Google may use what&rsquo;s
  sent (subtitle lines and your questions) to improve its services.</small>
</main>
<script>
  var form = document.getElementById('form');
  var input = document.getElementById('key');
  var send = document.getElementById('send');
  var status = document.getElementById('status');
  function say(text, kind) { status.textContent = text; status.className = kind || ''; }
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var key = input.value.trim();
    if (!key) { say('Paste your key first.', 'error'); return; }
    send.disabled = true;
    say('Checking your key…');
    fetch(location.pathname, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: key })
    }).then(function (r) { return r.json(); }).then(function (r) {
      if (r.ok) {
        form.style.display = 'none';
        say('Done: your TV has your key. You can close this page.', 'done');
      } else {
        send.disabled = false;
        say(r.error || "That key didn't work.", 'error');
      }
    }).catch(function () {
      send.disabled = false;
      say("Couldn't reach your TV. Check the key screen is still open on it, and that this phone is on the same Wi-Fi.", 'error');
    });
  });
</script>
</body>
</html>
''';
}
