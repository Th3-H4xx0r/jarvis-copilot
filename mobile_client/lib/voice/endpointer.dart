/// Adaptive end-of-speech detection for the realtime voice turn (plan 1.1).
///
/// Replaces the old fixed 1500 ms silence wait in [VoiceController]. It is pure
/// Dart — no platform channels, no timers, no I/O — so the whole policy is unit
/// testable: the caller feeds it (amplitude, frame duration) pairs and acts on
/// the returned event.
///
/// The rules mirror the browser endpointer (webui/static/voice.js) exactly so a
/// turn feels identical on phone and web:
///
///   • energy VAD with HYSTERESIS — a high threshold opens the turn, a lower one
///     closes it, so a voice hovering near the boundary can't chatter
///   • base 400 ms of silence ends a normal utterance
///   • extended to 700 ms when the speaker is probably mid-thought: the tail was
///     RISING in energy, or the utterance so far is very short
///   • an utterance under 250 ms of voiced audio is a blip (cough, door, mic
///     pop) — discarded, never endpointed
///   • 30 s hard cap so a stuck-open mic can't stream forever
library;

/// What [Endpointer.update] decided for this frame.
enum EndpointEvent {
  /// Keep listening.
  none,

  /// The user has stopped talking — end the turn now.
  endOfTurn,
}

class Endpointer {
  // ── Tuning constants (plan 1.1) ────────────────────────────────────────────
  // All normalized peak amplitudes 0..1, all durations in milliseconds. These
  // are the ONLY timing numbers in the endpointing path — nothing downstream
  // may hard-code a silence wait.

  /// Opens a turn. Calibrated against PEAK (not RMS) amplitude, matching the
  /// webui VAD — RMS runs several times smaller and would never cross this.
  static const double kSpeechThreshold = 0.08;

  /// Closes a turn. Deliberately LOWER than [kSpeechThreshold]: the gap is the
  /// hysteresis band that stops a voice sitting near the boundary from
  /// flapping between "speaking" and "silent" every frame.
  static const double kSilenceThreshold = 0.04;

  /// Normal end-of-speech wait. 400 ms is about the shortest pause a listener
  /// reads as "your turn"; the old constant was 1500 ms, which by itself put a
  /// full second of dead air into every turn (plan 1.1, −1.0 s).
  static const int kBaseSilenceMs = 400;

  /// Used instead of [kBaseSilenceMs] when the speaker looks mid-thought (see
  /// [requiredSilenceMs]). Long enough to ride out a breath, short enough that
  /// a genuinely finished turn still beats the old fixed wait by ~2×.
  static const int kExtendedSilenceMs = 700;

  /// An utterance with less voiced audio than this gets the extended window —
  /// people who have only said one word ("Jarvis…") are usually still loading
  /// the rest of the sentence.
  static const int kShortUtteranceMs = 600;

  /// Less voiced audio than this is not speech at all. We discard it (reset to
  /// pre-speech) rather than ending a turn on a cough or a mic pop.
  static const int kMinUtteranceMs = 250;

  /// Hard cap on one utterance. Beyond this we endpoint regardless — a mic that
  /// never goes quiet (fan, TV, pocket) must not stream forever.
  static const int kMaxUtteranceMs = 30000;

  /// Window of voiced audio compared against the window before it to decide
  /// whether the tail is rising.
  static const int kTailWindowMs = 150;

  /// The tail counts as rising when its mean energy exceeds the preceding
  /// window's by this factor. 1.15 ignores ordinary syllable-to-syllable
  /// wobble while still catching a genuine "…and —" lift.
  static const double kRisingTailRatio = 1.15;

  // ── State ─────────────────────────────────────────────────────────────────
  bool _speaking = false;
  int _speechMs = 0; // total ms since the turn opened (voiced + trailing silence)
  int _silenceMs = 0; // ms of contiguous sub-threshold audio at the tail
  bool _risingTail = false; // latched when the current silence run began

  /// Recent VOICED frames as (durationMs, amplitude), newest last. Bounded to
  /// two tail windows — that's all [_computeRisingTail] ever looks at.
  final List<_Frame> _tail = [];

  /// True while a turn is open (speech has started and hasn't been endpointed).
  bool get speaking => _speaking;

  /// Milliseconds since the turn opened, including the trailing silence.
  int get speechMs => _speechMs;

  /// Milliseconds of contiguous silence at the tail (0 while voiced).
  int get silenceMs => _silenceMs;

  /// Milliseconds of actual voiced audio in this turn.
  int get voicedMs => _speechMs - _silenceMs;

  /// How much trailing silence must accumulate before this turn ends. Extended
  /// when the speaker is probably mid-thought — a rising tail, or barely any
  /// speech yet.
  /// While silence is running we use the value latched at its onset; while
  /// still voiced we evaluate the tail live, so the getter always answers for
  /// the audio seen so far.
  int get requiredSilenceMs {
    final rising = _silenceMs > 0 ? _risingTail : _computeRisingTail();
    return (rising || voicedMs < kShortUtteranceMs)
        ? kExtendedSilenceMs
        : kBaseSilenceMs;
  }

  /// Feed one mic frame. [amp] is the frame's normalized PEAK amplitude (0..1)
  /// and [dtMs] its duration — use [frameMsForPcm16] rather than a wall clock so
  /// the decision is driven by the audio itself and can't drift with scheduler
  /// jitter.
  EndpointEvent update(double amp, int dtMs) {
    if (dtMs <= 0) return EndpointEvent.none;

    if (!_speaking) {
      if (amp > kSpeechThreshold) {
        _speaking = true;
        _speechMs = dtMs;
        _silenceMs = 0;
        _risingTail = false;
        _tail
          ..clear()
          ..add(_Frame(dtMs, amp));
      }
      return EndpointEvent.none;
    }

    _speechMs += dtMs;

    if (amp < kSilenceThreshold) {
      // Latch the rising-tail verdict at the moment silence starts: the tail
      // shape can't change once the speaker has stopped, and re-deciding every
      // frame would let the window flip mid-wait.
      if (_silenceMs == 0) _risingTail = _computeRisingTail();
      _silenceMs += dtMs;

      if (voicedMs < kMinUtteranceMs) {
        // Not speech — a blip. Discard the "turn" once we've waited out the
        // longest window, so the detector is ready for the real utterance and
        // can't sit wedged in `speaking` forever.
        if (_silenceMs >= kExtendedSilenceMs) reset();
        return EndpointEvent.none;
      }
      if (_silenceMs >= requiredSilenceMs) return EndpointEvent.endOfTurn;
    } else {
      // Anything at or above the LOW threshold counts as still talking — this
      // is the hysteresis band. Restart the silence budget from scratch.
      _silenceMs = 0;
      _risingTail = false;
      _pushTail(dtMs, amp);
    }

    // Checked last so a max-length turn still ends even while the mic is loud.
    if (_speechMs >= kMaxUtteranceMs) return EndpointEvent.endOfTurn;
    return EndpointEvent.none;
  }

  /// Return to the pre-speech state (new turn, barge-in, teardown).
  void reset() {
    _speaking = false;
    _speechMs = 0;
    _silenceMs = 0;
    _risingTail = false;
    _tail.clear();
  }

  void _pushTail(int dtMs, double amp) {
    _tail.add(_Frame(dtMs, amp));
    var total = 0;
    for (final f in _tail) {
      total += f.ms;
    }
    // Keep two windows' worth; drop from the front once we have more.
    while (_tail.length > 1 && total - _tail.first.ms >= kTailWindowMs * 2) {
      total -= _tail.first.ms;
      _tail.removeAt(0);
    }
  }

  /// True when the last [kTailWindowMs] of voiced audio is meaningfully louder
  /// than the window before it — the speaker was getting louder as they paused,
  /// which usually means they're not done.
  bool _computeRisingTail() {
    if (_tail.length < 2) return false;
    var recentMs = 0, priorMs = 0;
    var recentSum = 0.0, priorSum = 0.0;
    for (var i = _tail.length - 1; i >= 0; i--) {
      final f = _tail[i];
      if (recentMs < kTailWindowMs) {
        recentMs += f.ms;
        recentSum += f.amp * f.ms;
      } else if (priorMs < kTailWindowMs) {
        priorMs += f.ms;
        priorSum += f.amp * f.ms;
      } else {
        break;
      }
    }
    if (recentMs == 0 || priorMs == 0) return false;
    final recent = recentSum / recentMs;
    final prior = priorSum / priorMs;
    return recent > prior * kRisingTailRatio;
  }

  /// Duration of a mono PCM16 buffer of [byteLength] bytes at [sampleRate].
  /// Frame timing comes from the audio itself, never from `DateTime.now()`.
  static int frameMsForPcm16(int byteLength, int sampleRate) {
    if (byteLength <= 0 || sampleRate <= 0) return 0;
    return (byteLength ~/ 2) * 1000 ~/ sampleRate;
  }
}

class _Frame {
  const _Frame(this.ms, this.amp);
  final int ms;
  final double amp;
}
