import 'package:flutter/material.dart';

import '../theme.dart';
import 'coding_controller.dart';
import 'coding_models.dart';

/// Shared composer attachment UI (photos + files), used by both the terminal
/// composer and the chat input bar. The controller owns the picked-but-unsent
/// list; on send it uploads each and folds `@path` refs into the message.

Future<void> showAttachSheet(
    BuildContext context, CodingSessionsController c) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: JcTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tile(context, Icons.photo_camera_rounded, 'Camera',
                c.pickCameraPhoto),
            _tile(context, Icons.photo_library_rounded, 'Photo',
                c.pickGalleryPhoto),
            _tile(context, Icons.attach_file_rounded, 'File', c.pickFiles),
          ],
        ),
      ),
    ),
  );
}

Widget _tile(BuildContext context, IconData icon, String label,
    Future<void> Function() onTap) {
  return ListTile(
    leading: Icon(icon, color: JcTheme.primaryBlueHi),
    title: Text(label,
        style: const TextStyle(
            color: JcTheme.text, fontWeight: FontWeight.w600)),
    onTap: () {
      Navigator.of(context).pop();
      onTap();
    },
  );
}

/// A small "+" attach button for a composer.
class AttachButton extends StatelessWidget {
  const AttachButton({super.key, required this.controller, this.enabled = true});

  final CodingSessionsController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_circle_outline_rounded, color: JcTheme.muted),
      tooltip: 'Attach photo or file',
      onPressed: enabled ? () => showAttachSheet(context, controller) : null,
    );
  }
}

/// Horizontal strip of pending-attachment chips above a composer (collapses to
/// nothing when there are none). Listens to the controller so picks/removes
/// reflect immediately.
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({super.key, required this.controller});

  final CodingSessionsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.attachments;
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          height: 38,
          margin: const EdgeInsets.only(bottom: 6),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => _chip(controller, items[i]),
          ),
        );
      },
    );
  }

  Widget _chip(CodingSessionsController c, PendingAttachment a) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            a.isImage
                ? Icons.image_rounded
                : Icons.insert_drive_file_rounded,
            size: 15,
            color: JcTheme.muted,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: JcTheme.text, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 15, color: JcTheme.muted),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => c.removeAttachment(a),
          ),
        ],
      ),
    );
  }
}
