// ============================================================
// lib/presentation/screens/profile_screen.dart
// Manage user memory blocks securely in offline SQLite database.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/memory.dart';
import '../../data/services/supabase_service.dart';
import '../providers/profile_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  String _searchQuery = '';
  String _selectedCategory = 'all';

  final List<String> _categories = [
    'all',
    'academic',
    'professional',
    'skill',
    'project',
    'general',
  ];

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(profileProvider);
    final controller = ref.read(profileProvider.notifier);
    final theme = Theme.of(context);

    // Compute stats
    final totalCount = state.memories.length;
    final Map<String, int> catCounts = {};
    for (final m in state.memories) {
      final cat = (m.metadata['category'] as String? ?? 'general').toLowerCase();
      catCounts[cat] = (catCounts[cat] ?? 0) + 1;
    }

    // Filter memories
    final filtered = state.memories.where((m) {
      final content = m.content.toLowerCase();
      final cat = (m.metadata['category'] as String? ?? 'general').toLowerCase();
      final matchesSearch = content.contains(_searchQuery.toLowerCase());
      final matchesCat = _selectedCategory == 'all' || cat == _selectedCategory;
      return matchesSearch && matchesCat;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile & Memory Vault'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => controller.loadMemories(),
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- User Info and Stats card ----
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                    child: Icon(
                      Icons.person,
                      size: 32,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          SupabaseService.currentUserEmail.isNotEmpty
                              ? SupabaseService.currentUserEmail
                              : 'Local User',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Master Key decrypted • E2EE enabled',
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            _statChip('Total: $totalCount', theme),
                            if (catCounts['academic'] != null)
                              _statChip('Academic: ${catCounts['academic']}', theme),
                            if (catCounts['professional'] != null)
                              _statChip('Professional: ${catCounts['professional']}', theme),
                            if (catCounts['skill'] != null)
                              _statChip('Skills: ${catCounts['skill']}', theme),
                            if (catCounts['project'] != null)
                              _statChip('Projects: ${catCounts['project']}', theme),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---- Search and Filters ----
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search memory blocks...',
                      prefixIcon: const Icon(Icons.search),
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      filled: true,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Category Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: _categories.map((cat) {
                final isSelected = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(cat.toUpperCase()),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedCategory = cat);
                      }
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // ---- Memories list ----
          Expanded(
            child: state.loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.isEmpty
                              ? 'No memory blocks found in this category.'
                              : 'No memories matching your search.',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final m = filtered[i];
                          return _MemoryCard(
                            memory: m,
                            onEdit: () => _showEditDialog(m, controller),
                            onDelete: () => _confirmDelete(m, controller),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add memory block',
        child: const Icon(Icons.add),
        onPressed: () => _showAddDialog(controller),
      ),
    );
  }

  Widget _statChip(String text, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
    );
  }

  void _showEditDialog(Memory memory, ProfileController controller) {
    final textCtrl = TextEditingController(text: memory.content);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Memory Block'),
        content: SizedBox(
          width: 450,
          child: TextField(
            controller: textCtrl,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'Enter updated memory description...',
            ),
          ),
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            child: const Text('Save'),
            onPressed: () {
              if (textCtrl.text.trim().isNotEmpty) {
                controller.editMemory(memory.id, textCtrl.text.trim());
                Navigator.pop(ctx);
              }
            },
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Memory memory, ProfileController controller) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Memory Block?'),
        content: const Text(
          'This will permanently delete this fact/context from T.I.M.\'s local vault index. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
            onPressed: () {
              controller.deleteMemory(memory.id);
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _showAddDialog(ProfileController controller) {
    final textCtrl = TextEditingController();
    String category = 'general';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Memory Block'),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: _categories
                      .where((c) => c != 'all')
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c.toUpperCase()),
                          ),)
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => category = val);
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: textCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Describe this fact or experience in detail...',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(ctx),
            ),
            ElevatedButton(
              child: const Text('Add'),
              onPressed: () {
                if (textCtrl.text.trim().isNotEmpty) {
                  controller.addMemory(textCtrl.text.trim(), category);
                  Navigator.pop(ctx);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.memory,
    required this.onEdit,
    required this.onDelete,
  });

  final Memory memory;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cat = (memory.metadata['category'] as String? ?? 'general').toLowerCase();

    // Dynamically color category badges
    Color catColor;
    switch (cat) {
      case 'academic':
        catColor = Colors.purpleAccent;
      case 'professional':
        catColor = Colors.blueAccent;
      case 'skill':
        catColor = Colors.greenAccent;
      case 'project':
        catColor = Colors.orangeAccent;
      default:
        catColor = Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: catColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: catColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    cat.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: catColor,
                    ),
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: onEdit,
                      tooltip: 'Edit block',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: onDelete,
                      tooltip: 'Delete block',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              memory.content,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (memory.metadata['source'] != null)
              Text(
                'Source: ${memory.metadata['source']}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
