import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/knowledge_base.dart';

class KnowledgeBaseService extends ChangeNotifier {
  List<KBStudy> _studies = [];
  List<KBArticle> _articles = [];
  List<KBCategory> _categories = [];
  String? _apiKey;
  bool _isLoaded = false;

  List<KBStudy> get studies => _studies;
  List<KBArticle> get articles => _articles;
  List<KBCategory> get categories => _categories;
  bool get isLoaded => _isLoaded;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  KnowledgeBaseService() {
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
    _apiKey = prefs.getString('anthropic_api_key');
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('anthropic_api_key', _apiKey!);
    notifyListeners();
  }

  Future<void> clearApiKey() async {
    _apiKey = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('anthropic_api_key');
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
      final response = await http.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': _apiKey!,
          'anthropic-version': '2023-06-01',
        },
        body: json.encode({
          'model': 'claude-sonnet-4-20250514',
          'max_tokens': 512,
          'system': systemPrompt,
          'messages': [
            {'role': 'user', 'content': question},
          ],
        }),
      );

      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final content = body['content'] as List;
        if (content.isNotEmpty) {
          return (content[0] as Map<String, dynamic>)['text'] as String;
        }
        return 'No response received.';
      } else if (response.statusCode == 401) {
        return 'Invalid API key. Please check your key in Settings.';
      } else {
        return 'API error (${response.statusCode}). Please try again later.';
      }
    } catch (e) {
      return 'Connection error. Please check your internet connection and try again.';
    }
  }
}
