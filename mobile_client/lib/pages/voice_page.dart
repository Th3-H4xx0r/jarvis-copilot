import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../api/sessions.dart';
import '../api/voice.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/orb_visualizer.dart';

class VoicePage extends StatefulWidget {
  const VoicePage({super.key});

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  static const int _sampleRate = 16000;

  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final ValueNotifier<double> _amp = ValueNotifier(0);
  final List<int> _pcm = [];

  late final VoiceApi _voice;
  late final SessionsApi _sessions;

  StreamSubscription<Uint8List>? _recordSub;
  bool _recording = false;
  bool _processing = false;
  String _status = 'Ready';
  String _transcript = '';
  String _reply = '';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _voice = VoiceApi(app.api);
    _sessions = SessionsApi(app.api);
  }

  @override
  void dispose() {
    _recordSub?.cancel();
    _amp.dispose();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_processing) return;
    if (_recording) {
      await _stopAndSend();
      return;
    }
    await _startRecording();
  }

  Future<void> _startRecording() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      _showError('Mic permission denied');
      return;
    }
    await _player.stop();
    _pcm.clear();
    _recordSub?.cancel();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 4096,
      ),
    );
    _recordSub = stream.listen((chunk) {
      _pcm.addAll(chunk);
      _amp.value = _pcmAmplitude(chunk);
    });
    setState(() {
      _recording = true;
      _processing = false;
      _status = 'Listening';
      _transcript = '';
      _reply = '';
      _error = '';
    });
  }

  Future<void> _stopAndSend() async {
    setState(() {
      _recording = false;
      _processing = true;
      _status = 'Transcribing';
      _error = '';
    });
    try {
      await _recorder.stop();
      await _recordSub?.cancel();
      _recordSub = null;
      _amp.value = 0;

      final audio = Uint8List.fromList(_pcm);
      _pcm.clear();
      if (audio.length < 1000) {
        _showError("Didn't catch that. Try again.");
        return;
      }

      final sessionId = await _ensureSessionId();
      var sawSegment = false;
      await for (final event in _voice.qualityTurn(
        audioBase64: base64.encode(audio),
        sampleRate: _sampleRate,
        sessionId: sessionId,
      )) {
        if (!mounted) return;
        final type = (event['type'] ?? '').toString();
        if (type == 'transcript') {
          setState(() {
            _transcript = (event['text'] ?? '').toString();
            _status = _transcript.trim().isEmpty ? 'No speech' : 'Thinking';
          });
        } else if (type == 'segment') {
          sawSegment = true;
          final kind = (event['kind'] ?? '').toString();
          if (kind == 'tool') {
            setState(() {
              final name = (event['name'] ?? 'tool').toString();
              _status = 'Running $name';
            });
          } else if (kind == 'text') {
            final text = (event['text'] ?? '').toString();
            final audioBase64 = (event['audio_base64'] ?? '').toString();
            setState(() {
              if (text.isNotEmpty) {
                _reply = _reply.isEmpty ? text : '$_reply\n\n$text';
              }
              _status = audioBase64.isEmpty ? 'Thinking' : 'Speaking';
            });
            if (audioBase64.isNotEmpty) {
              await _playAudio(audioBase64);
            }
          }
        } else if (type == 'error') {
          _showError((event['error'] ?? 'Voice request failed').toString());
          return;
        } else if (type == 'done') {
          break;
        }
      }
      if (!sawSegment && _error.isEmpty) {
        setState(() => _status = 'Ready');
      } else if (mounted && _error.isEmpty) {
        setState(() => _status = 'Ready');
      }
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _recording = false;
        });
      }
    }
  }

  Future<String> _ensureSessionId() async {
    final sessions = await _sessions.list();
    for (final session in sessions) {
      final sid = (session['session_id'] ?? '').toString();
      if (sid.isNotEmpty) return sid;
    }
    final created = await _sessions.create(title: 'Voice');
    final sid = (created['session_id'] ?? '').toString();
    if (sid.isEmpty) throw StateError('Could not create a chat session');
    return sid;
  }

  Future<void> _playAudio(String audioBase64) async {
    try {
      final bytes = base64.decode(audioBase64);
      await _player.play(BytesSource(bytes));
    } catch (_) {
      // Text is already visible, so audio decode failures should not break the turn.
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _status = 'Error';
      _processing = false;
      _recording = false;
      _amp.value = 0;
    });
  }

  double _pcmAmplitude(Uint8List chunk) {
    if (chunk.lengthInBytes < 2) return 0;
    final data = chunk.buffer.asByteData(chunk.offsetInBytes, chunk.lengthInBytes);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
      final sample = data.getInt16(i, Endian.little) / 32768.0;
      sum += sample * sample;
      count++;
    }
    if (count == 0) return 0;
    return math.sqrt(sum / count).clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _recording || _processing;
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(title: const Text('Voice')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              const SizedBox(height: 12),
              OrbVisualizer(amplitude: _amp, size: 240),
              const SizedBox(height: 22),
              _StatusPill(
                label: _status,
                active: busy,
                error: _error.isNotEmpty,
              ),
              const SizedBox(height: 22),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_transcript.isNotEmpty)
                        _VoiceCard(label: 'You', text: _transcript),
                      if (_reply.isNotEmpty)
                        _VoiceCard(label: 'JarvisCopilot', text: _reply),
                      if (_error.isNotEmpty)
                        _VoiceCard(label: 'Error', text: _error, error: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: _toggleRecord,
                child: Container(
                  width: 152,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: _recording
                        ? const LinearGradient(
                            colors: [JcTheme.danger, JcTheme.accentAlt],
                          )
                        : JcTheme.brandGradient,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66E0552B),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _recording ? Icons.stop : Icons.mic,
                        color: Colors.black,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _recording ? 'Stop' : 'Talk',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.active,
    required this.error,
  });

  final String label;
  final bool active;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? JcTheme.danger : (active ? JcTheme.accent : JcTheme.muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: JcTheme.surface,
        border: Border.all(color: JcTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _VoiceCard extends StatelessWidget {
  const _VoiceCard({
    required this.label,
    required this.text,
    this.error = false,
  });

  final String label;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: JcTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: error ? JcTheme.danger : JcTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: error ? JcTheme.danger : JcTheme.accent,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: JcTheme.text, height: 1.35)),
        ],
      ),
    );
  }
}
