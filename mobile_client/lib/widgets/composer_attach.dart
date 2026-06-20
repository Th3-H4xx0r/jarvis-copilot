import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// A reusable composer attachment component (photos / videos / files).
///
/// The host (a controller) owns the picked-but-unsent list and the pickers; this
/// file is just the shared UI + the [ComposerAttachHost] contract so any composer
/// (currently the main chat) can get attach support without duplicating widgets.

/// A composer attachment the user picked but hasn't sent yet.
class PendingAttachment {
  PendingAttachment({
    required this.name,
    required this.bytes,
    this.isImage = false,
    this.isVideo = false,
    this.posterBytes,
  });

  final String name;
  final Uint8List bytes;
  final bool isImage;

  /// True for a video: on send the file is uploaded AND [posterBytes] (a
  /// first-frame JPEG) is uploaded separately as a vision image.
  final bool isVideo;
  final Uint8List? posterBytes;

  int get size => bytes.length;
}

/// What a composer must expose for the shared attach UI. Implemented by a
/// `ChangeNotifier` controller (hence `implements Listenable`).
abstract class ComposerAttachHost implements Listenable {
  List<PendingAttachment> get attachments;
  Future<void> pickCameraPhoto();
  Future<void> pickGalleryPhoto();
  Future<void> pickVideo();
  Future<void> pickFiles();
  void removeAttachment(PendingAttachment a);
}

/// The "+" attach button for a composer row.
class AttachButton extends StatelessWidget {
  const AttachButton({super.key, required this.host, this.enabled = true});

  final ComposerAttachHost host;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_circle_outline_rounded, color: JcTheme.muted),
      tooltip: 'Attach photo, video, or file',
      onPressed: enabled ? () => showAttachSheet(context, host) : null,
    );
  }
}

Future<void> showAttachSheet(BuildContext context, ComposerAttachHost host) async {
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
                host.pickCameraPhoto),
            _tile(context, Icons.photo_library_rounded, 'Photo',
                host.pickGalleryPhoto),
            _tile(context, Icons.videocam_rounded, 'Video', host.pickVideo),
            _tile(context, Icons.attach_file_rounded, 'File', host.pickFiles),
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

/// Horizontal strip of pending-attachment chips above a composer (collapses to
/// nothing when there are none). Listens to the host so picks/removes reflect
/// immediately.
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({super.key, required this.host});

  final ComposerAttachHost host;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final items = host.attachments;
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          height: 38,
          margin: const EdgeInsets.only(bottom: 6),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => _chip(host, items[i]),
          ),
        );
      },
    );
  }

  Widget _chip(ComposerAttachHost host, PendingAttachment a) {
    final icon = a.isVideo
        ? Icons.movie_rounded
        : a.isImage
            ? Icons.image_rounded
            : Icons.insert_drive_file_rounded;
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
          Icon(icon, size: 15, color: JcTheme.muted),
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
            onPressed: () => host.removeAttachment(a),
          ),
        ],
      ),
    );
  }
}
