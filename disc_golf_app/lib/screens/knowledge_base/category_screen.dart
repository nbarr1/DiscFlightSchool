import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/knowledge_base.dart';
import '../../services/knowledge_base_service.dart';
import 'article_detail_screen.dart';

class CategoryScreen extends StatelessWidget {
  final KBCategory category;

  const CategoryScreen({Key? key, required this.category}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<KnowledgeBaseService>(context);
    final tips = service.getArticles(category: category.id, type: 'tip');
    final faqs = service.getArticles(category: category.id, type: 'faq');
    final color = Color(category.colorValue);

    return Scaffold(
      appBar: AppBar(
        title: Text(category.name),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              category.description,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
            if (tips.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Tips',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              ...tips.map((tip) => _buildTipCard(context, tip, service, color)),
            ],
            if (faqs.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'Frequently Asked Questions',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              ...faqs.map((faq) => _buildFaqTile(context, faq, service, color)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTipCard(
    BuildContext context,
    KBArticle tip,
    KnowledgeBaseService service,
    Color color,
  ) {
    final source =
        tip.sourceIds.isNotEmpty ? service.getStudy(tip.sourceIds.first) : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: color.withAlpha(25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb, color: Colors.amber.shade300, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tip.question,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tip.answer,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            if (source != null) ...[
              const SizedBox(height: 6),
              Text(
                '— ${source.citation}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFaqTile(
    BuildContext context,
    KBArticle faq,
    KnowledgeBaseService service,
    Color color,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        title: Text(
          faq.question,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        trailing: Icon(Icons.chevron_right, color: color),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ArticleDetailScreen(article: faq),
          ),
        ),
      ),
    );
  }
}
