import '../../models/knowledge_base.dart';

/// Read boundary for bundled and eventually remotely refreshed knowledge content.
abstract interface class KnowledgeBaseRepository {
  Future<List<KBCategory>> getCategories();
  Future<List<KBStudy>> getStudies();
  Future<List<KBArticle>> getArticles();
  Future<List<KBArticle>> searchArticles(String query);
  Future<List<KBArticle>> getArticlesForCategory(String categoryId);
}
