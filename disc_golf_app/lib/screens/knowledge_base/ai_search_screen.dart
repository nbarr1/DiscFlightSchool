import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/knowledge_base_service.dart';

class AISearchScreen extends StatefulWidget {
  const AISearchScreen({Key? key}) : super(key: key);

  @override
  State<AISearchScreen> createState() => _AISearchScreenState();
}

class _AISearchScreenState extends State<AISearchScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_QAPair> _history = [];
  bool _isLoading = false;
  bool _useAI = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _askQuestion() async {
    final question = _controller.text.trim();
    if (question.isEmpty) return;

    final service =
        Provider.of<KnowledgeBaseService>(context, listen: false);

    setState(() {
      _history.add(_QAPair(question: question));
      _isLoading = _useAI && service.hasApiKey;
    });
    _controller.clear();

    String answer;
    if (_useAI && service.hasApiKey) {
      _scrollToBottom();
      answer = await service.askQuestion(question);
    } else {
      answer = service.searchLocal(question);
    }

    if (mounted) {
      setState(() {
        _history.last = _QAPair(
          question: question,
          answer: answer,
          isAI: _useAI && service.hasApiKey,
        );
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask About Disc Golf'),
      ),
      body: Column(
        children: [
          // Chat history
          Expanded(
            child: _history.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _history.length,
                    itemBuilder: (context, index) {
                      final qa = _history[index];
                      return _buildQAPair(qa);
                    },
                  ),
          ),

          // Loading indicator (only for AI calls)
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.teal.shade300,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Asking AI...',
                    style: TextStyle(
                      color: Colors.teal.shade300,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 48, color: Colors.teal.shade300),
            const SizedBox(height: 16),
            const Text(
              'Search the Research',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Get answers backed by peer-reviewed disc golf research from 11 studies.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildSuggestionChip('What muscles matter most for backhand?'),
                _buildSuggestionChip('Where should my thumb be on the disc?'),
                _buildSuggestionChip('How do pros putt differently?'),
                _buildSuggestionChip('What speed should I throw at my level?'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String text) {
    return ActionChip(
      label: Text(text, style: const TextStyle(fontSize: 12)),
      backgroundColor: Colors.teal.withAlpha(30),
      side: BorderSide(color: Colors.teal.withAlpha(60)),
      onPressed: () {
        _controller.text = text;
        _askQuestion();
      },
    );
  }

  Widget _buildQAPair(_QAPair qa) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User question
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8, left: 48),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade800,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(qa.question, style: const TextStyle(fontSize: 14)),
          ),
        ),

        // Answer
        if (qa.answer != null)
          Container(
            margin: const EdgeInsets.only(bottom: 16, right: 48),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.teal.shade900.withAlpha(100),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.teal.withAlpha(50)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      qa.isAI ? Icons.auto_awesome : Icons.menu_book,
                      size: 16,
                      color: Colors.teal.shade300,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      qa.isAI ? 'AI Answer' : 'Research Says',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.teal.shade300,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  qa.answer!,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildInputBar() {
    final service = Provider.of<KnowledgeBaseService>(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey.shade800),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // AI toggle (only shown when API key is set)
            if (service.hasApiKey)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Local',
                      style: TextStyle(
                        fontSize: 12,
                        color: !_useAI
                            ? Colors.teal.shade300
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 24,
                      child: Switch(
                        value: _useAI,
                        onChanged: (v) => setState(() => _useAI = v),
                        activeThumbColor: Colors.purple.shade300,
                        inactiveTrackColor: Colors.teal.withAlpha(60),
                        inactiveThumbColor: Colors.teal.shade300,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome,
                            size: 12,
                            color: _useAI
                                ? Colors.purple.shade300
                                : Colors.grey.shade600),
                        const SizedBox(width: 3),
                        Text(
                          'AI',
                          style: TextStyle(
                            fontSize: 12,
                            color: _useAI
                                ? Colors.purple.shade300
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Ask a question...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _askQuestion(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isLoading ? null : _askQuestion,
                  icon: Icon(Icons.send, color: Colors.teal.shade300),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QAPair {
  final String question;
  final String? answer;
  final bool isAI;

  _QAPair({required this.question, this.answer, this.isAI = false});
}
