import 'package:flutter/material.dart';

import '../services/api_client.dart' show apiErrorMessage;
import '../theme.dart';

/// Owns the loading / error / empty / [RefreshIndicator] boilerplate that every
/// data screen needs, so each screen only describes how to load and how to
/// render. Provide a [loader] returning T and a [builder] that renders the
/// loaded data; [isEmpty] decides whether to show [emptyText] instead.
///
/// Pass an [AsyncViewController] to trigger a reload imperatively (e.g. after a
/// mutation): `controller.refresh()`.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.loader,
    required this.builder,
    this.isEmpty,
    this.emptyText = 'Nothing here yet.',
    this.controller,
  });

  final Future<T> Function() loader;
  final Widget Function(BuildContext context, T data, Future<void> Function() refresh)
      builder;
  final bool Function(T data)? isEmpty;
  final String emptyText;
  final AsyncViewController? controller;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

/// Handle for triggering a reload from outside the [AsyncView] (after a
/// create/edit/delete). Attach it via [AsyncView.controller].
class AsyncViewController {
  _AsyncViewState? _state;

  /// Reload the view's data. No-op if the view isn't mounted.
  Future<void> refresh() async => _state?._load();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  T? _data;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _load();
  }

  @override
  void didUpdateWidget(covariant AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) oldWidget.controller?._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final d = await widget.loader();
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _data == null) {
      return _CenterMsg(_error!, color: JcTheme.danger, onRetry: _load);
    }
    final data = _data as T;
    final empty = widget.isEmpty?.call(data) ?? false;
    return RefreshIndicator(
      onRefresh: _load,
      child: empty
          ? ListView(
              children: [
                const SizedBox(height: 120),
                _CenterMsg(widget.emptyText),
              ],
            )
          : widget.builder(context, data, _load),
    );
  }
}

class _CenterMsg extends StatelessWidget {
  const _CenterMsg(this.text, {this.color = JcTheme.muted, this.onRetry});
  final String text;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center, style: TextStyle(color: color)),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
}
