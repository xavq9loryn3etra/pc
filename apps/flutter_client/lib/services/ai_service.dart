import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';
import 'tmdb_service.dart';

/// What [AiService.suggest] came back with: a line or two about the picks,
/// and the picks themselves, each a title the app can open. [offTopic] when
/// the request wasn't about something to watch — [message] then says so.
class AiAnswer {
  final bool offTopic;
  final String message;
  final List<Movie> titles;

  /// The model's reply as it gave it, for passing back with later
  /// questions (see AiService.suggest's history).
  final String reply;

  /// The streaming service the request asked for ("Netflix"), if any —
  /// [titles] are then only ones on it where the user is — and how many
  /// suggestions were left out for not being on it there.
  final String? service;
  final int leftOut;

  /// None of the suggestions were on [service] there: [titles] are all of
  /// them anyway, as they can still be watched in the app.
  final bool noneOnService;

  const AiAnswer({
    required this.offTopic,
    required this.message,
    required this.titles,
    required this.reply,
    this.service,
    this.leftOut = 0,
    this.noneOnService = false,
  });
}

/// Why [AiService.suggest] couldn't answer, in words for the user.
class AiUnavailable implements Exception {
  final String message;
  const AiUnavailable(this.message);

  @override
  String toString() => message;
}

/// Suggests movies and shows for a scenario someone describes ("a
/// feel-good film for a rainy Sunday"), using Google's free Gemini API
/// tier — and only that: anything else is politely turned down.
///
/// Its key comes from the build (--dart-define GEMINI_API_KEY, see
/// secrets.json), never from the repo, which is public. On the free tier
/// it can't cost anything; the worst someone who digs it out of the app can
/// do is use up the day's free requests, hence [_dailyLimit] per phone.
class AiService {
  static final AiService _instance = AiService._();
  factory AiService() => _instance;
  AiService._();

  static const _key = String.fromEnvironment('GEMINI_API_KEY');

  /// Whether this build has a key to ask with.
  bool get available => _key.isNotEmpty;

  /// The models tried, in order, each when the ones before it are busy or
  /// failing. Fastest first: the Flash Lites answered in 3–10s (500 free
  /// requests a day each); the Gemma models take 30–55s, thinking first —
  /// which can't be turned off for them — but allow 14,400 a day.
  static const _models = [
    'gemini-3.5-flash-lite',
    'gemini-3.1-flash-lite',
    'gemma-4-26b-a4b-it',
    'gemma-4-31b-it',
  ];

  /// From this model on, answers take a while (see [_models]).
  static const slowFrom = 2;

  // A model that said it's busy (or failed), skipped until then.
  final Map<String, DateTime> _restingUntil = {};

  /// Questions a phone can ask a day: the free requests are shared by
  /// everyone using the app.
  static const _dailyLimit = 40;
  static const _countKey = 'ai_questions_v1';

  static const _instructions =
      '''You're Popcorn Ask, the friendly film buff inside the Popcorn app: you love movies and TV, and you help people find something they'll enjoy watching. That is all you do.
If the request isn't about finding something to watch (movies, TV shows, actors' work, genres, moods, occasions), set "offTopic" to true, leave "titles" empty, and in "message" say warmly, with a light touch, that movies and shows are your thing, and offer to help find something to watch.
Otherwise suggest up to 9 real, existing titles that fit, best first, with their original release year. If they name or describe a particular title ("Disney's live action Aladdin"), put that title first.
Only if the request asks what's on a particular streaming service ("on Netflix", "streaming on Prime"), set "service" to its name ("Netflix", "Prime Video", "Disney+"...); otherwise leave it null. A studio or brand that makes films (Disney, Marvel, Pixar, DreamWorks, Ghibli) is not a streaming service.
Write plainly: no dashes (— or –); use commas and full stops instead.
Earlier messages may come before the latest: use them to understand follow-ups ("something lighter", "more like the second one"), and don't suggest the same titles again unless asked.
Reply with JSON only, no markdown:
{"offTopic": false, "service": null, "message": "2-3 warm, chatty sentences, like a friend who loves films: why these fit what they asked for, with a little enthusiasm; no spoilers, no lists", "titles": [{"title": "...", "year": 2014, "type": "movie" or "tv", "language": "its original language as an ISO 639-1 code, e.g. en, ml, ko"}]}''';

  final Dio _dio = Dio();

  // How many earlier questions and answers go with a new one.
  static const _historyTurns = 3;

  /// Asks for suggestions for [request], following on from [history] —
  /// the earlier questions in the conversation and their answers, oldest
  /// first. [onModel] hears each model as it's tried, by its index in
  /// [_models] (see [slowFrom]). Throws [AiUnavailable] when no model could
  /// answer, or the phone's had its [_dailyLimit] for today.
  Future<AiAnswer> suggest(
    String request, {
    List<(String, AiAnswer)> history = const [],
    void Function(int model)? onModel,
  }) async {
    if (!available) {
      throw const AiUnavailable("Ask isn't set up in this version of the app.");
    }
    await _countQuestion();

    for (var i = 0; i < _models.length; i++) {
      final model = _models[i];
      final resting = _restingUntil[model];
      if (resting != null && DateTime.now().isBefore(resting)) continue;
      onModel?.call(i);
      try {
        final reply =
            await _ask(model, request, history: history, slow: i >= slowFrom);
        if (reply != null) return await _answerFrom(reply);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // Over its free limit for the minute: try it again in a minute.
        // Busy, failing or too slow: sooner.
        _restingUntil[model] = DateTime.now().add(status == 429
            ? const Duration(minutes: 1)
            : const Duration(seconds: 20));
      } on FormatException {
        // A reply that isn't the JSON asked for: the next model may do
        // better.
      }
    }
    throw const AiUnavailable(
        'Lots of people are asking right now. Try again in a minute.');
  }

  // The model's reply text, or null if it gave none.
  Future<String?> _ask(
    String model,
    String request, {
    required List<(String, AiAnswer)> history,
    required bool slow,
  }) async {
    Map<String, Object> turn(String role, String text) => {
          'role': role,
          'parts': [
            {'text': text}
          ],
        };
    final response = await _dio.post(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
      options: Options(
        headers: {'x-goog-api-key': _key},
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: Duration(seconds: slow ? 90 : 30),
      ),
      data: {
        'systemInstruction': {
          'parts': [
            {'text': _instructions}
          ]
        },
        'contents': [
          for (final (asked, answer) in history.length > _historyTurns
              ? history.sublist(history.length - _historyTurns)
              : history) ...[
            turn('user', asked),
            turn('model', answer.reply),
          ],
          turn('user', request),
        ],
        'generationConfig': {
          'temperature': 0.7,
          'responseMimeType': 'application/json',
        },
      },
    );
    final parts = (response.data['candidates'] as List?)
        ?.firstOrNull?['content']?['parts'] as List?;
    if (parts == null) return null;
    // Leaves out the "thinking" the Gemma models write first.
    return parts
        .where((p) => p['thought'] != true)
        .map((p) => p['text'] ?? '')
        .join();
  }

  // The model's JSON made into an answer, each title looked up on TMDB so
  // it's one that exists and can be opened.
  Future<AiAnswer> _answerFrom(String reply) async {
    // Some models wrap it in a ```json block anyway.
    final start = reply.indexOf('{'), end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException('no JSON');
    final json = jsonDecode(reply.substring(start, end + 1));
    if (json is! Map) throw const FormatException('not an object');

    // Without dashes, which the app's writing doesn't use: models put
    // them in anyway, now and then.
    final message = (json['message'] ?? '')
        .toString()
        .trim()
        .replaceAll(RegExp(r'\s*[—–]\s*'), ', ');
    if (json['offTopic'] == true) {
      return AiAnswer(
        reply: reply,
        offTopic: true,
        message: message.isEmpty
            ? 'I can only help you find movies and shows to watch.'
            : message,
        titles: const [],
      );
    }

    final picks = (json['titles'] as List? ?? const [])
        .whereType<Map>()
        .where((t) => t['title'] is String)
        .take(9)
        .toList();
    final found = await Future.wait([
      for (final t in picks)
        TMDBService().findTitle(
          t['title'] as String,
          year: t['year'] is int
              ? t['year'] as int
              : int.tryParse('${t['year']}'),
          type: t['type'] == 'tv' ? 'tv' : 'movie',
          language: t['language'] is String
              ? (t['language'] as String).toLowerCase()
              : null,
        ),
    ]);
    // In the model's order, each once.
    final seen = <String>{};
    var titles = [
      for (final movie in found)
        if (movie != null && seen.add('${movie.type}_${movie.id}')) movie,
    ];

    // A service asked for: only titles really on it where the user is —
    // its pages show its button. The model only knows roughly what's on
    // it, and mostly in the US.
    final service = json['service'] is String &&
            (json['service'] as String).trim().isNotEmpty
        ? (json['service'] as String).trim()
        : null;
    var leftOut = 0;
    var noneOnService = false;
    if (service != null) {
      final providers = await Future.wait([
        for (final movie in titles) TMDBService().streamingProvidersFor(movie)
      ]);
      final on = [
        for (var i = 0; i < titles.length; i++)
          if (providers[i].any((p) => _sameService(p.name, service))) titles[i],
      ];
      // None on it: all of them anyway, rather than nothing — they can
      // still be watched in the app.
      if (on.isNotEmpty) {
        leftOut = titles.length - on.length;
        titles = on;
      } else if (titles.isNotEmpty) {
        noneOnService = true;
      }
    }
    return AiAnswer(
      offTopic: false,
      message: message,
      titles: titles,
      reply: reply,
      service: service,
      leftOut: leftOut,
      noneOnService: noneOnService,
    );
  }

  // Whether TMDB's [provider] name is the [service] the model named:
  // "Amazon Prime Video" is "Prime Video", "Disney Plus" is "Disney+".
  static bool _sameService(String provider, String service) {
    String plain(String s) => s
        .toLowerCase()
        .replaceAll('+', 'plus')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final a = plain(provider), b = plain(service);
    return a.isNotEmpty && b.isNotEmpty && (a.contains(b) || b.contains(a));
  }

  // Counts a question against today's limit, or refuses it.
  Future<void> _countQuestion() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final saved = prefs.getString(_countKey)?.split('|');
    final count = saved != null && saved.length == 2 && saved[0] == today
        ? int.tryParse(saved[1]) ?? 0
        : 0;
    if (count >= _dailyLimit) {
      throw const AiUnavailable(
          "That's all the questions for today. Ask again tomorrow!");
    }
    await prefs.setString(_countKey, '$today|${count + 1}');
  }
}
