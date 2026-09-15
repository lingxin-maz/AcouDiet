// app/tool/gen_sample_wav.dart
//
// Generates `app/assets/demo/sample_chews.wav` -- the bundled sample Demo Mode B replays.
//
//   dart run tool/gen_sample_wav.dart
//
// The sample is generated rather than recorded because the offline build has no microphone
// and no network to fetch a corpus. It goes through the *same* decoder and the *same*
// pipeline as a recorded file, so the injection path is exercised for real; swapping in a
// recorded wav later requires no code change, only a re-run of the parity checks.

import 'dart:io';

import '../lib/data/wav_decoder.dart';

void main(List<String> args) {
  final seconds = args.isNotEmpty ? int.tryParse(args.first) ?? 20 : 20;
  final pcm = DemoSignal.chewingPcm16(seconds: seconds);
  final wav = DemoSignal.wrapWav(pcm);

  final out = File('assets/demo/sample_chews.wav');
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(wav);
  stdout.writeln(
      'wrote ${out.path}  (${seconds}s, ${pcm.length} PCM bytes, ${wav.length} total)');

  // Read it straight back: a sample that cannot be decoded is worse than no sample.
  final decoded = WavDecoder.decode(out.readAsBytesSync());
  stdout.writeln('verified: ${decoded.sampleRate} Hz, ${decoded.channels} ch, '
      '${decoded.pcm16.length ~/ 2} samples');
}
