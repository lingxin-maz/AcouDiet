import 'dart:typed_data';

import '../core/errors.dart';
import '../core/feature_config.g.dart' as cfg;

/// Minimal RIFF/WAVE reader for Demo Mode B (`SPEC-M-02`).
///
/// Mode B injects the decoded PCM straight into the ring buffer -- it must **never** play
/// the sample through the speaker and re-record it (`API-01` section 2.6: that would add a
/// room response, noise and an obvious "we are playing a recording" tell).
///
/// Only the frozen format is accepted (16 kHz, mono, PCM16). Refusing anything else is
/// deliberate: silently resampling would make the demo produce different numbers than the
/// real path, which is exactly what the injection-equivalence acceptance checks for.
class WavDecoder {
  WavDecoder._();

  static const int _pcmFormat = 1;

  static ({Uint8List pcm16, int sampleRate, int channels}) decode(Uint8List bytes) {
    if (bytes.length < 44) throw Errors.asset('demo', 'wav too short');
    if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46) {
      throw Errors.asset('demo', 'missing RIFF header');
    }

    final data = ByteData.sublistView(bytes);
    var pos = 12;
    var foundFmt = false;
    var audioFormat = _pcmFormat;
    var channels = 1;
    var sampleRate = cfg.FeatureConfig.sampleRate;
    var bitsPerSample = 16;
    Uint8List? payload;

    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
      final size = data.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ') {
        audioFormat = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
        foundFmt = true;
      } else if (id == 'data') {
        final end = (body + size) <= bytes.length ? body + size : bytes.length;
        payload = Uint8List.sublistView(bytes, body, end);
      }
      pos = body + size + (size & 1); // chunks are word-aligned
    }

    if (!foundFmt) throw Errors.asset('demo', 'no fmt chunk');
    if (audioFormat != _pcmFormat) {
      throw Errors.asset('demo', 'only PCM wav is supported (format=$audioFormat)');
    }
    if (bitsPerSample != 16) {
      throw Errors.asset('demo', 'only 16-bit PCM is supported ($bitsPerSample)');
    }
    if (sampleRate != cfg.FeatureConfig.sampleRate) {
      throw Errors.asset('demo', 'sample rate must be ${cfg.FeatureConfig.sampleRate}');
    }
    if (channels != cfg.FeatureConfig.channels) {
      throw Errors.asset('demo', 'must be mono, got $channels channels');
    }
    final pcm = payload;
    if (pcm == null || pcm.isEmpty) throw Errors.asset('demo', 'no data chunk');

    return (pcm16: pcm, sampleRate: sampleRate, channels: channels);
  }
}

/// Generates the sample audio Mode B replays, for the offline demo path.
///
/// The real project ships recorded wavs; offline (no network, no recorder) this produces a
/// deterministic chewing-like PCM16 stream that exercises the *same* pipeline, so the demo
/// path and the live path can still be compared for equivalence.
class DemoSignal {
  DemoSignal._();

  static Uint8List chewingPcm16({
    required int seconds,
    double intervalSeconds = 0.7,
    int seed = 20260910,
  }) {
    final sr = cfg.FeatureConfig.sampleRate;
    final n = (sr * seconds).round();
    final samples = Int16List(n);
    var state = seed;
    int nextRandom() {
      // xorshift32: deterministic, no external package.
      state ^= state << 13;
      state ^= state >> 17;
      state ^= state << 5;
      return state & 0x7fffffff;
    }

    final step = (sr * intervalSeconds).round();
    final decay = (0.004 * sr).round();
    var start = 0;
    while (start < n) {
      for (var i = 0; i < 600 && start + i < n; i++) {
        final env = _exp(-i / decay);
        final v = env * _sin(2 * 3.141592653589793 * 1800.0 * i / sr) * 0.7;
        final jitter = 1.0 + (nextRandom() % 100 - 50) / 1000.0;
        final s = (v * jitter * 32767.0).round().clamp(-32768, 32767);
        samples[start + i] = s;
      }
      start += step;
    }

    final out = Uint8List(n * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < n; i++) {
      bd.setInt16(i * 2, samples[i], Endian.little);
    }
    return out;
  }

  /// Builds a complete RIFF/WAVE container around [pcm16].
  static Uint8List wrapWav(Uint8List pcm16) {
    final out = Uint8List(44 + pcm16.length);
    final bd = ByteData.sublistView(out);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        out[at + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    bd.setUint32(4, 36 + pcm16.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, cfg.FeatureConfig.channels, Endian.little);
    bd.setUint32(24, cfg.FeatureConfig.sampleRate, Endian.little);
    final byteRate = cfg.FeatureConfig.sampleRate * cfg.FeatureConfig.channels * 2;
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, cfg.FeatureConfig.channels * 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bd.setUint32(40, pcm16.length, Endian.little);
    out.setRange(44, 44 + pcm16.length, pcm16);
    return out;
  }

  // Minimal math helpers so this file stays free of dart:math imports it does not need.
  static double _exp(double x) {
    var t = 1.0;
    var sum = 1.0;
    for (var i = 1; i < 18; i++) {
      t *= x / i;
      sum += t;
    }
    return sum;
  }

  static double _sin(double x) {
    // Wrap to [-pi, pi] and use a 7th-order Taylor series: plenty for a demo signal.
    const twoPi = 6.283185307179586;
    var y = x % twoPi;
    if (y > 3.141592653589793) y -= twoPi;
    if (y < -3.141592653589793) y += twoPi;
    final y2 = y * y;
    return y * (1 - y2 / 6 + y2 * y2 / 120 - y2 * y2 * y2 / 5040);
  }
}
