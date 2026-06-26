// ============================================================
// lib/presentation/screens/genesis_screen.dart
// Phase 3 — Genesis Onboarding.
//
// Flow:
//   blank    -> "I don't know your story yet. Drop your resume, or
//               tell me about your journey."
//   drafting -> resume dropped; LLM extracting Memory Blocks
//   review   -> user edits / deletes / adds blocks (Memory Block cards)
//   confirmed-> vectorise + persist into the local vault
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/onboarding_provider.dart';
import '../widgets/drag_drop_zone.dart';
import '../widgets/memory_block.dart';

class GenesisScreen extends ConsumerWidget {
  const GenesisScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(genesisProvider);
    final ctrl = ref.read(genesisProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Genesis — getting to know you')),
      body: switch (state.phase) {
        GenesisPhase.blank => _BlankSlate(
            onResume: (text) {
              // Stub: production hooks this to a PDF text extractor
              // (syncfusion_flutter_pdf) + ctrl.extractFromResume(text).
              ctrl.extractFromResume(text);
            },
            onTellJourney: (text) {
              ctrl.extractFromResume(text);
            },
          ),
        GenesisPhase.drafting => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(state.extracting
                    ? 'Reading your story…'
                    : 'Drafting Memory Blocks…',),
              ],
            ),
          ),
        GenesisPhase.review => _ReviewDashboard(state: state, ctrl: ctrl),
        GenesisPhase.confirmed => _ConfirmedGate(ctrl: ctrl),
      },
    );
  }
}

class _BlankSlate extends StatelessWidget {
  const _BlankSlate({required this.onResume, required this.onTellJourney});
  final ValueChanged<String> onResume;
  final ValueChanged<String> onTellJourney;

  @override
  Widget build(BuildContext context) {
    final journeyCtrl = TextEditingController();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, size: 48,
                  color: Color(0xFF8AB4F8),),
              const SizedBox(height: 16),
              Text(
                'I don\'t know your story yet.',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Let\'s change that. Drop your resume, or tell me about '
                'your journey.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              // Drag-and-drop zone for PDFs / text files.
              DragDropZone(
                onText: (text) => onResume(text),
                onFile: (path) {
                  // Stub: real impl reads PDF via syncfusion_flutter_pdf.
                  onResume('Path dropped: $path');
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: journeyCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Or type a few paragraphs about yourself…',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () =>
                    onTellJourney(journeyCtrl.text),
                child: const Text('Tell T.I.M. my story'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewDashboard extends StatelessWidget {
  const _ReviewDashboard({required this.state, required this.ctrl});
  final GenesisState state;
  final GenesisController ctrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Confirm what I learned. Edit, delete, or add context '
                  'before I save it.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Confirm all & save'),
                onPressed: () => ctrl.confirmAll(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: state.blocks.length,
            itemBuilder: (_, i) {
              final b = state.blocks[i];
              return MemoryBlockCard(
                block: b,
                onToggleConfirm: () => ctrl.toggleConfirm(b.draftId),
                onDelete: () => ctrl.deleteBlock(b.draftId),
                onEdit: (text) => ctrl.editBlock(b.draftId, text),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConfirmedGate extends StatelessWidget {
  const _ConfirmedGate({required this.ctrl});
  final GenesisController ctrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_open, size: 48,
              color: Color(0xFF81C995),),
          const SizedBox(height: 16),
          Text('Memory baseline saved.',
              style: Theme.of(context).textTheme.titleLarge,),
          const SizedBox(height: 8),
          const Text(
            'Your vault is now encrypted and ready. T.I.M. will only '
            'remember what you confirmed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
