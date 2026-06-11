import 'package:flutter/material.dart';

import '../theme.dart';
import 'coding_controller.dart';
import 'coding_models.dart';

/// Watches the controller for pending remote permission requests and shows the
/// most recent one as an approval card (Approve / Deny / Reply). The push
/// notification is the primary away-from-app surface; this is the in-app view.
class PermissionApprovalBanner extends StatelessWidget {
  const PermissionApprovalBanner({super.key, required this.controller});

  final CodingSessionsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pend = controller.pendingApprovals;
        if (pend.isEmpty) return const SizedBox.shrink();
        return _ApprovalCard(
          key: ValueKey(pend.first.requestId),
          controller: controller,
          permission: pend.first,
          extra: pend.length - 1,
        );
      },
    );
  }
}

class _ApprovalCard extends StatefulWidget {
  const _ApprovalCard({
    super.key,
    required this.controller,
    required this.permission,
    this.extra = 0,
  });

  final CodingSessionsController controller;
  final PendingPermission permission;
  final int extra; // "+N more" waiting

  @override
  State<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<_ApprovalCard> {
  final _reply = TextEditingController();
  bool _replying = false;
  bool _busy = false;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _respond(String decision, {String? message}) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.respondPermission(
      widget.permission.requestId,
      decision: decision,
      message: message,
    );
    // The controller drops it from pendingApprovals → this card rebuilds away.
  }

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFFC084FC);
    final p = widget.permission;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: purple.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: purple.withValues(alpha: 0.36)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline_rounded, size: 16, color: purple),
                const SizedBox(width: 7),
                const Text('Claude needs approval',
                    style: TextStyle(
                        color: purple,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                  widget.extra > 0
                      ? '${p.projectLabel} · +${widget.extra}'
                      : p.projectLabel,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0D13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                p.summary.isEmpty ? p.tool : p.summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFFB9BFC9),
                    fontSize: 12.5,
                    fontFamily: 'Menlo'),
              ),
            ),
            const SizedBox(height: 10),
            if (_replying) ...[
              TextField(
                controller: _reply,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Tell Claude what to do instead…',
                  hintStyle: const TextStyle(color: JcTheme.muted),
                  filled: true,
                  fillColor: JcTheme.glassFill,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: JcTheme.glassBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: JcTheme.glassBorder),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _replying = false),
                    child: const Text('Cancel',
                        style: TextStyle(color: JcTheme.muted)),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _respond('deny', message: _reply.text),
                    style: FilledButton.styleFrom(backgroundColor: purple),
                    child: const Text('Send to Claude'),
                  ),
                ],
              ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _respond('deny'),
                      icon: const Icon(Icons.close_rounded, size: 17),
                      label: const Text('Deny'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: JcTheme.danger,
                        side: const BorderSide(color: JcTheme.glassBorder),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _busy ? null : () => setState(() => _replying = true),
                    tooltip: 'Reply / steer',
                    icon: const Icon(Icons.reply_rounded, color: purple),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _respond('allow'),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF34D399),
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
