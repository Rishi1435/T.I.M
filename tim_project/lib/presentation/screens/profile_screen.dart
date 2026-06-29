// ============================================================
// lib/presentation/screens/profile_screen.dart
// Redesigned premium inline Memory Vault screen.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
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
    final palette = theme.extension<TimPalette>()!;

    // Filter memories
    final filtered = state.memories.where((m) {
      final content = m.content.toLowerCase();
      final cat = (m.metadata['category'] as String? ?? 'general').toLowerCase();
      final matchesSearch = content.contains(_searchQuery.toLowerCase());
      final matchesCat = _selectedCategory == 'all' || cat == _selectedCategory;
      return matchesSearch && matchesCat;
    }).toList();

    return Container( // Inline container instead of Scaffold
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SingleChildScrollView(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Text(
                  'Memory Vault',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your verified context blocks, securely encrypted offline.',
                  style: TextStyle(color: palette.textSecondary, fontSize: 15),
                ),
                const SizedBox(height: 40),

                // Card 1: Identity & Multi-Tenant Access
                _buildCard(
                  title: 'Identity & Multi-Tenant Access',
                  palette: palette,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: palette.surfaceVariant,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'R',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w500,
                                color: palette.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  SupabaseService.currentUserEmail.isNotEmpty
                                      ? SupabaseService.currentUserEmail.split('@').first
                                      : 'Rishi Pediredla',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  SupabaseService.currentUserEmail.isNotEmpty
                                      ? SupabaseService.currentUserEmail
                                      : 'Location: Kakinada, AP · Expected Graduation: May 2027',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: palette.success.withValues(alpha: 0.1),
                                    border: Border.all(color: palette.success.withValues(alpha: 0.2)),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.security, size: 14, color: palette.success),
                                      const SizedBox(width: 6),
                                      Text(
                                        'AES-256-GCM Secured Vault',
                                        style: TextStyle(
                                          color: palette.success,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Card 2: Reflexion Log (Self-Correction)
                _buildCard(
                  title: 'Reflexion Log (Self-Correction)',
                  palette: palette,
                  child: Column(
                    children: [
                      _buildWarningBlock(
                        title: 'Agentic AI Articulation Gap',
                        description:
                            'Flagged 2 days ago. You struggled to explain Agentic AI architecture clearly. T.I.M. will drill this concept in your next session.',
                        palette: palette,
                      ),
                      const SizedBox(height: 16),
                      _buildWarningBlock(
                        title: 'Cadence Pauses > 2.5s',
                        description:
                            'Detected today during mock interview. T.I.M. voice lock will now interrupt to correct pacing if hesitation exceeds threshold.',
                        palette: palette,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Card 3: Verified Memory Blocks
                _buildCard(
                  title: 'Verified Memory Blocks',
                  palette: palette,
                  action: IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: () => _showAddDialog(controller),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Search field
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Search memory blocks...',
                          prefixIcon: const Icon(Icons.search),
                          fillColor: palette.surfaceVariant,
                          filled: true,
                        ),
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                      const SizedBox(height: 16),

                      // Category filters
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _categories.map((cat) {
                            final isSelected = _selectedCategory == cat;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
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
                      const SizedBox(height: 20),

                      // Memories List
                      state.loading
                          ? const Center(child: CircularProgressIndicator())
                          : filtered.isEmpty && _searchQuery.isEmpty && _selectedCategory == 'all'
                              ? _buildDefaultBlocks(palette, controller)
                              : Column(
                                  children: [
                                    ...filtered.map((m) => _buildMemoryBlock(
                                          memory: m,
                                          palette: palette,
                                          onEdit: () => _showEditDialog(m, controller),
                                          onDelete: () => _confirmDelete(m, controller),
                                        )),
                                  ],
                                ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Display standard defaults if database is empty so that it looks exactly like the HTML mock
  Widget _buildDefaultBlocks(TimPalette palette, ProfileController controller) {
    final mock1 = Memory(
      id: 'default_1',
      userId: '',
      content: 'Full Stack Developer Intern specializing in mobile and backend systems. Experience with cloud-native architectures.',
      metadata: {'category': 'skill', 'tags': ['Flutter', 'Node.js', 'Spring Boot', 'AWS Lambda']},
      createdAt: DateTime.now(),
    );
    final mock2 = Memory(
      id: 'default_2',
      userId: '',
      content: 'Core Pair Lead managing a 7-engineer team on an AI voice mock interview platform. Recently substituted Firestore for PostgreSQL\'s JSONB column type for efficiency. Swapped development roles for Meghana and Sai.',
      metadata: {'category': 'project', 'tags': ['System Architecture', 'Team Leadership']},
      createdAt: DateTime.now(),
    );
    return Column(
      children: [
        _buildMemoryBlock(
          memory: mock1,
          palette: palette,
          onEdit: () => _showEditDialog(mock1, controller),
          onDelete: () => _confirmDelete(mock1, controller),
        ),
        _buildMemoryBlock(
          memory: mock2,
          palette: palette,
          onEdit: () => _showEditDialog(mock2, controller),
          onDelete: () => _confirmDelete(mock2, controller),
        ),
      ],
    );
  }

  Widget _buildCard({
    required String title,
    required TimPalette palette,
    required Widget child,
    Widget? action,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildWarningBlock({
    required String title,
    required String description,
    required TimPalette palette,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(16),
        border: Border(
          left: BorderSide(color: palette.danger, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: palette.danger, size: 20),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: palette.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryBlock({
    required Memory memory,
    required TimPalette palette,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    final cat = (memory.metadata['category'] as String? ?? 'general').toLowerCase();
    final List<String> tags = List<String>.from(memory.metadata['tags'] ?? []);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(16),
        border: Border(
          left: BorderSide(color: palette.primary, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            cat == 'project' ? Icons.assignment : Icons.code,
            color: palette.primary,
            size: 20,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      cat.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.primary,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          onPressed: onEdit,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          onPressed: onDelete,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  memory.content,
                  style: TextStyle(
                    fontSize: 14,
                    color: palette.textSecondary,
                    height: 1.5,
                  ),
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: tags
                        .map((t) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.3),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
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
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: _categories
                      .where((c) => c != 'all')
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c.toUpperCase()),
                          ))
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
