import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/knowledge_base.dart';
import '../../services/knowledge_base_service.dart';

class ArticleDetailScreen extends StatelessWidget {
  final KBArticle article;

  const ArticleDetailScreen({Key? key, required this.article})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final service =
        Provider.of<KnowledgeBaseService>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FAQ Detail'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Question
            Text(
              article.question,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),

            // Answer
            Text(
              article.answer,
              style: const TextStyle(fontSize: 15, height: 1.6),
            ),

            // Key findings
            if (article.keyFindings.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Key Findings',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              ...article.keyFindings.map(
                (finding) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('  •  ',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                      Expanded(
                        child:
                            Text(finding, style: const TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Sources
            if (article.sourceIds.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  Icon(Icons.menu_book,
                      size: 20, color: Colors.teal.shade300),
                  const SizedBox(width: 8),
                  Text(
                    'Sources',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...article.sourceIds.map((id) {
                final study = service.getStudy(id);
                if (study == null) return const SizedBox.shrink();
                return _buildSourceCard(context, study);
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceCard(BuildContext context, KBStudy study) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.teal.shade900.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              study.citation,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.teal.shade200,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              study.title,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              study.summary,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade400,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
