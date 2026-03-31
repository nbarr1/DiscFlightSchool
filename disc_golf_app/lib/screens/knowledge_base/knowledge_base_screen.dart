import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/knowledge_base.dart';
import '../../services/knowledge_base_service.dart';
import 'ai_search_screen.dart';
import 'category_screen.dart';

class KnowledgeBaseScreen extends StatefulWidget {
  const KnowledgeBaseScreen({Key? key}) : super(key: key);

  @override
  State<KnowledgeBaseScreen> createState() => _KnowledgeBaseScreenState();
}

class _KnowledgeBaseScreenState extends State<KnowledgeBaseScreen> {
  KBArticle? _randomTip;

  @override
  void initState() {
    super.initState();
    final service =
        Provider.of<KnowledgeBaseService>(context, listen: false);
    service.loadData().then((_) {
      if (mounted) {
        setState(() {
          _randomTip = service.getRandomTip();
        });
      }
    });
  }

  static const _categoryIcons = <String, IconData>{
    'accessibility_new': Icons.accessibility_new,
    'album': Icons.album,
    'map': Icons.map,
    'psychology': Icons.psychology,
  };

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<KnowledgeBaseService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge Base'),
      ),
      body: !service.isLoaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Search bar
                  _buildSearchBar(context),
                  const SizedBox(height: 16),

                  // Random tip
                  if (_randomTip != null) ...[
                    _buildTipCard(_randomTip!, service),
                    const SizedBox(height: 20),
                  ],

                  // Category grid
                  _buildCategoryGrid(service),
                ],
              ),
            ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AISearchScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.teal.withAlpha(80)),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: Colors.teal.shade300),
            const SizedBox(width: 12),
            Text(
              'Ask a question...',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            Icon(Icons.auto_awesome, color: Colors.teal.shade300, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildTipCard(KBArticle tip, KnowledgeBaseService service) {
    final source = tip.sourceIds.isNotEmpty
        ? service.getStudy(tip.sourceIds.first)
        : null;

    return Card(
      color: Colors.teal.shade900.withAlpha(120),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb, color: Colors.amber.shade300, size: 20),
                const SizedBox(width: 8),
                Text(
                  tip.question,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade200,
                    fontSize: 14,
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
              const SizedBox(height: 8),
              Text(
                '— ${source.citation}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.teal.shade300,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryGrid(KnowledgeBaseService service) {
    final categories = service.categories;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.15,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final cat = categories[index];
        final color = Color(cat.colorValue);
        final icon = _categoryIcons[cat.iconName] ?? Icons.article;
        final articleCount = service.getArticleCount(cat.id);
        final studyCount = service.getStudyCount(cat.id);

        return Card(
          color: color.withAlpha(35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: color.withAlpha(80)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CategoryScreen(category: cat),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withAlpha(50),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const Spacer(),
                  Text(
                    cat.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$studyCount ${studyCount == 1 ? "study" : "studies"} · $articleCount tips',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
