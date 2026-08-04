import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/knowledge_base.dart';

class KnowledgeBaseService extends ChangeNotifier {
  List<KBStudy> _studies = [];
  List<KBArticle> _articles = [];
  List<KBCategory> _categories = [];
  String? _apiKey;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  bool _isLoaded = false;

  /// HTTP client used for AI search. Injectable so tests can exercise the
  /// request/response handling without network access.
  final http.Client _client;
  final bool _ownsClient;

  List<KBStudy> get studies => _studies;
  List<KBArticle> get articles => _articles;
  List<KBCategory> get categories => _categories;
  bool get isLoaded => _isLoaded;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  /// Pass [client] from tests to stub the Anthropic API; production callers
  /// use the default constructor and get a client owned by this service.
  KnowledgeBaseService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null {
    _loadApiKey();
  }

  Future<void> loadData() async {
    if (_isLoaded) return;
    final jsonStr =
        await rootBundle.loadString('assets/data/knowledge_base.json');
    final data = json.decode(jsonStr) as Map<String, dynamic>;

    _studies = (data['studies'] as List)
        .map((e) => KBStudy.fromJson(e as Map<String, dynamic>))
        .toList();
    _categories = (data['categories'] as List)
        .map((e) => KBCategory.fromJson(e as Map<String, dynamic>))
        .toList();
    _articles = (data['articles'] as List)
        .map((e) => KBArticle.fromJson(e as Map<String, dynamic>))
        .toList();

    _isLoaded = true;
    notifyListeners();
  }

  List<KBArticle> getArticles({String? category, String? type}) {
    return _articles.where((a) {
      if (category != null && a.category != category) return false;
      if (type != null && a.type != type) return false;
      return true;
    }).toList();
  }

  int getArticleCount(String categoryId) {
    return _articles.where((a) => a.category == categoryId).length;
  }

  int getStudyCount(String categoryId) {
    final articleSourceIds = _articles
        .where((a) => a.category == categoryId)
        .expand((a) => a.sourceIds)
        .toSet();
    return articleSourceIds.length;
  }

  KBArticle? getRandomTip() {
    final tips = _articles.where((a) => a.isTip).toList();
    if (tips.isEmpty) return null;
    return tips[Random().nextInt(tips.length)];
  }

  KBStudy? getStudy(String id) {
    try {
      return _studies.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  // ---- API key management ----

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      _apiKey = await _secureStorage.read(key: 'anthropic_api_key');
      final legacyKey = prefs.getString('anthropic_api_key');
      if ((_apiKey == null || _apiKey!.isEmpty) &&
          legacyKey != null &&
          legacyKey.isNotEmpty) {
        _apiKey = legacyKey;
        await _secureStorage.write(key: 'anthropic_api_key', value: legacyKey);
      }
      await prefs.remove('anthropic_api_key');
      notifyListeners();
    } catch (e) {
      debugPrint('Secure storage unavailable for Anthropic API key: $e');
      _apiKey = null;
    }
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    try {
      if (_apiKey!.isEmpty) {
        await _secureStorage.delete(key: 'anthropic_api_key');
      } else {
        await _secureStorage.write(key: 'anthropic_api_key', value: _apiKey!);
      }
    } catch (e) {
      debugPrint('Failed to update Anthropic API key in secure storage: $e');
    }
    notifyListeners();
  }

  Future<void> clearApiKey() async {
    _apiKey = null;
    try {
      await _secureStorage.delete(key: 'anthropic_api_key');
    } catch (e) {
      debugPrint('Failed to clear Anthropic API key from secure storage: $e');
    }
    notifyListeners();
  }

  // ---- Local keyword search ----

  static final _punctuation = RegExp(r'[^\w\s]');

  List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(_punctuation, '')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toList();
  }

  int _countMatches(List<String> keywords, String text) {
    final lower = text.toLowerCase();
    return keywords.where((k) => lower.contains(k)).length;
  }

  String searchLocal(String query) {
    final keywords = _tokenize(query);
    if (keywords.isEmpty) return 'Please enter a more specific question.';

    // Score each article
    final scored = <MapEntry<KBArticle, int>>[];
    for (final article in _articles) {
      final qScore = _countMatches(keywords, article.question) * 3;
      final aScore = _countMatches(keywords, article.answer);
      final fScore = article.keyFindings
              .map((f) => _countMatches(keywords, f))
              .fold<int>(0, (a, b) => a + b) *
          2;
      final total = qScore + aScore + fScore;
      if (total > 0) scored.add(MapEntry(article, total));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));

    if (scored.isEmpty) {
      return 'No matching research found for your question. Try different '
          'keywords, or browse the categories for tips and FAQs.';
    }

    // Take top results (up to 3 for a readable answer)
    final top = scored.take(3).toList();
    final buf = StringBuffer();

    for (var i = 0; i < top.length; i++) {
      final article = top[i].key;
      if (i > 0) buf.writeln('\n---\n');

      buf.writeln(article.question);
      buf.writeln();
      buf.writeln(article.answer);

      // Add source citations
      final sources = article.sourceIds
          .map((id) => getStudy(id))
          .where((s) => s != null)
          .toList();
      if (sources.isNotEmpty) {
        buf.writeln();
        buf.write('Sources: ');
        buf.writeln(sources.map((s) => s!.citation).join(', '));
      }
    }

    return buf.toString().trim();
  }

  // ---- Claude API ----

  /// Model used for AI search. Kept as a named constant so the migration
  /// point is obvious the next time the model line moves.
  static const String claudeModel = 'claude-sonnet-5';

  /// Output cap for an answer. The system prompt asks for <200 words
  /// (~300 tokens); the headroom absorbs citation-heavy replies without
  /// truncating mid-sentence.
  static const int claudeMaxTokens = 1024;

  static const Duration claudeTimeout = Duration(seconds: 45);

  /// Pull the answer text out of a `/v1/messages` response body.
  ///
  /// `content` is a heterogeneous block list — with adaptive thinking enabled
  /// the first block can be a `thinking` block that carries no `text` field,
  /// so blocks must be selected by `type` rather than by position.
  /// Multiple text blocks are concatenated (citations can split them).
  ///
  /// Returns null when the response carries no text block at all.
  @visibleForTesting
  static String? extractAnswerText(Map<String, dynamic> body) {
    final content = body['content'];
    if (content is! List) return null;

    final buffer = StringBuffer();
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] != 'text') continue;
      final text = block['text'];
      if (text is String) buffer.write(text);
    }

    final joined = buffer.toString().trim();
    return joined.isEmpty ? null : joined;
  }

  /// Map a non-200 response to a user-facing message.
  @visibleForTesting
  static String messageForErrorStatus(int statusCode) {
    switch (statusCode) {
      case 401:
        return 'Invalid API key. Please check your key in Settings.';
      case 403:
        return 'This API key is not permitted to use AI search. Check the '
            'key\'s permissions in the Anthropic Console.';
      case 429:
        return 'Rate limited by the Anthropic API. Please wait a moment and '
            'try again.';
      case 529:
        return 'The Anthropic API is temporarily overloaded. Please try again '
            'in a moment.';
      default:
        if (statusCode >= 500) {
          return 'Anthropic API server error ($statusCode). Please try again '
              'later.';
        }
        return 'API error ($statusCode). Please try again later.';
    }
  }

  Future<String> askQuestion(String question) async {
    if (!hasApiKey) {
      return 'Please add your Anthropic API key in Settings to use AI search.';
    }

    final studySummaries = _studies
        .map((s) => '- ${s.citation}: "${s.title}" — ${s.summary}')
        .join('\n');

    final systemPrompt = '''You are a disc golf research assistant embedded in the Disc Flight School app. Answer questions using ONLY the peer-reviewed research summaries provided below. Be concise, practical, and cite sources by author name and year. If the research doesn't cover the question, say so honestly.

Research library:
$studySummaries

Guidelines:
- Cite sources inline, e.g. (Greenway, 2007)
- Give actionable advice when possible
- Use specific numbers from the research
- Keep answers under 200 words''';

    try {
      final response = await _client
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': _apiKey!,
              'anthropic-version': '2023-06-01',
            },
            body: json.encode({
              'model': claudeModel,
              'max_tokens': claudeMaxTokens,
              // Grounded Q&A over a small supplied corpus with a <200-word
              // answer: thinking buys little here and costs the user latency
              // and tokens on their own key. Disabled explicitly because on
              // claude-sonnet-5 omitting `thinking` runs adaptive by default.
              'thinking': {'type': 'disabled'},
              'system': systemPrompt,
              'messages': [
                {'role': 'user', 'content': question},
              ],
            }),
          )
          .timeout(claudeTimeout);

      if (response.statusCode != 200) {
        return messageForErrorStatus(response.statusCode);
      }

      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return 'Unexpected response from the Anthropic API. Please try again.';
      }

      if (decoded['stop_reason'] == 'refusal') {
        return 'Claude declined to answer that question. Try rephrasing it '
            'around the disc golf research in the library.';
      }

      final answer = extractAnswerText(decoded);
      if (answer == null) {
        return 'No response received.';
      }

      if (decoded['stop_reason'] == 'max_tokens') {
        return '$answer\n\n_(Answer was cut off at the length limit — try '
            'asking a narrower question.)_';
      }

      return answer;
    } on TimeoutException {
      return 'The request to Anthropic timed out. Please check your '
          'connection and try again.';
    } catch (e) {
      debugPrint('AI search request failed: $e');
      return 'Connection error. Please check your internet connection and try again.';
    }
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
