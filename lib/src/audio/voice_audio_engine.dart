/// 100% custom, zero-dependency PCM/WAV Audio Engine, Procedural Game SFX
/// Synthesizer, Multi-Voice Stereo Mixer, IMA-ADPCM 4:1 Voice Codec, VAD Noise
/// Gate, Jitter Buffer, and 3D Proximity Multiplayer Voice Chat (VoIP).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';
import 'audio_backend.dart';

/// Raw decoded 16-bit PCM audio buffer (mono or interleaved stereo).
class PcmBuffer {
  PcmBuffer(
    this.samples, {
    this.sampleRate = 44100,
    this.channels = 1,
  });

  final Int16List samples;
  final int sampleRate;
  final int channels;

  int get frameCount => samples.length ~/ channels;
  double get durationSeconds => frameCount / sampleRate;
}

/// 100% custom RIFF/WAVE PCM 16-bit encoder & decoder (zero external packages).
class WavCodec {
  const WavCodec._();

  static Uint8List encode(PcmBuffer buf) {
    final dataBytes = buf.samples.length * 2;
    final out = ByteData(44 + dataBytes);
    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    final byteRate = buf.sampleRate * buf.channels * 2;
    final blockAlign = buf.channels * 2;

    writeAscii(0, 'RIFF');
    out.setUint32(4, 36 + dataBytes, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    out.setUint32(16, 16, Endian.little); // PCM chunk size
    out.setUint16(20, 1, Endian.little); // PCM format = 1
    out.setUint16(22, buf.channels, Endian.little);
    out.setUint32(24, buf.sampleRate, Endian.little);
    out.setUint32(28, byteRate, Endian.little);
    out.setUint16(32, blockAlign, Endian.little);
    out.setUint16(34, 16, Endian.little); // bits per sample
    writeAscii(36, 'data');
    out.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < buf.samples.length; i++) {
      out.setInt16(44 + i * 2, buf.samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static PcmBuffer decode(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const FormatException('WAV buffer too short');
    }
    final bd = ByteData.sublistView(bytes);
    if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46) {
      throw const FormatException('Missing RIFF header');
    }
    var channels = 1;
    var sampleRate = 44100;
    var bitsPerSample = 16;
    var offset = 12;

    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = bd.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        bitsPerSample = bd.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (bitsPerSample != 16) {
          throw FormatException('Only 16-bit PCM WAV is supported (got $bitsPerSample)');
        }
        final count = math.min(size, bytes.length - body) ~/ 2;
        final samples = Int16List(count);
        for (var i = 0; i < count; i++) {
          samples[i] = bd.getInt16(body + i * 2, Endian.little);
        }
        return PcmBuffer(samples, sampleRate: sampleRate, channels: channels);
      }
      offset = body + size + (size & 1);
    }
    throw const FormatException('WAV data chunk not found');
  }
}

/// Procedural zero-asset game SFX synthesizer so developers have instant sound
/// effects (jump, coin, laser, explosion, engine) without external files.
class SfxSynth {
  const SfxSynth._();

  static PcmBuffer coin({int sampleRate = 22050}) {
    final n = (sampleRate * 0.24).round();
    final out = Int16List(n);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final freq = t < 0.08 ? 987.77 : 1318.51; // B5 -> E6 chime
      phase += 2.0 * math.pi * freq / sampleRate;
      final env = math.exp(-t * 10.0);
      out[i] = (math.sin(phase) * env * 24000).round().clamp(-32767, 32767);
    }
    return PcmBuffer(out, sampleRate: sampleRate, channels: 1);
  }

  static PcmBuffer jump({int sampleRate = 22050}) {
    final n = (sampleRate * 0.22).round();
    final out = Int16List(n);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final freq = 220.0 + t * 1400.0;
      phase += 2.0 * math.pi * freq / sampleRate;
      final env = (1.0 - t / 0.22).clamp(0.0, 1.0);
      out[i] = (math.sin(phase) * env * 22000).round().clamp(-32767, 32767);
    }
    return PcmBuffer(out, sampleRate: sampleRate, channels: 1);
  }

  static PcmBuffer laser({int sampleRate = 22050}) {
    final n = (sampleRate * 0.18).round();
    final out = Int16List(n);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final freq = 1400.0 * math.exp(-t * 11.0);
      phase += 2.0 * math.pi * freq / sampleRate;
      final env = (1.0 - t / 0.18).clamp(0.0, 1.0);
      final sq = math.sin(phase) >= 0 ? 1.0 : -1.0;
      out[i] = (sq * env * 15000).round().clamp(-32767, 32767);
    }
    return PcmBuffer(out, sampleRate: sampleRate, channels: 1);
  }

  static PcmBuffer explosion({int sampleRate = 22050}) {
    final n = (sampleRate * 0.45).round();
    final out = Int16List(n);
    final rng = math.Random(1337);
    var lp = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final white = rng.nextDouble() * 2.0 - 1.0;
      lp = lp * 0.88 + white * 0.12;
      final env = math.exp(-t * 5.5);
      out[i] = (lp * env * 28000).round().clamp(-32767, 32767);
    }
    return PcmBuffer(out, sampleRate: sampleRate, channels: 1);
  }
}

class _ActiveVoice {
  _ActiveVoice({
    required this.id,
    required this.buffer,
    required this.volume,
    required this.pan,
    required this.pitch,
    required this.loop,
  });

  final int id;
  final PcmBuffer buffer;
  double volume;
  double pan;
  double pitch;
  bool loop;
  double cursor = 0.0;
  bool paused = false;
  bool stopped = false;
}

/// Real-time stereo multi-voice PCM software mixer implementing [AudioBackend].
/// Works on every platform (Mobile, Desktop, Web) with zero third-party plugins.
class PcmSoftwareAudioBackend implements AudioBackend {
  PcmSoftwareAudioBackend({this.sampleRate = 22050, this.maxVoices = 64});

  final int sampleRate;
  final int maxVoices;

  final Map<int, _ActiveVoice> _voices = {};
  int _nextId = 1;

  @override
  int play(
    AudioClip clip, {
    required double volume,
    required double pan,
    required double pitch,
    required bool loop,
  }) {
    PcmBuffer? pcm;
    if (clip.source is PcmBuffer) {
      pcm = clip.source as PcmBuffer;
    } else if (clip.source is Uint8List) {
      pcm = WavCodec.decode(clip.source as Uint8List);
    } else {
      pcm = SfxSynth.coin(sampleRate: sampleRate);
    }

    if (_voices.length >= maxVoices) {
      _voices.remove(_voices.keys.first);
    }
    final id = _nextId++;
    _voices[id] = _ActiveVoice(
      id: id,
      buffer: pcm,
      volume: volume.clamp(0.0, 2.0),
      pan: pan.clamp(-1.0, 1.0),
      pitch: pitch.clamp(0.25, 4.0),
      loop: loop,
    );
    return id;
  }

  @override
  void update(int voice, {double? volume, double? pan, double? pitch}) {
    final v = _voices[voice];
    if (v == null) return;
    if (volume != null) v.volume = volume.clamp(0.0, 2.0);
    if (pan != null) v.pan = pan.clamp(-1.0, 1.0);
    if (pitch != null) v.pitch = pitch.clamp(0.25, 4.0);
  }

  @override
  void pause(int voice) => _voices[voice]?.paused = true;

  @override
  void resume(int voice) => _voices[voice]?.paused = false;

  @override
  void stop(int voice) {
    final v = _voices.remove(voice);
    if (v != null) v.stopped = true;
  }

  @override
  bool isPlaying(int voice) {
    final v = _voices[voice];
    return v != null && !v.stopped;
  }

  @override
  void dispose() => _voices.clear();

  /// Renders [frameCount] stereo frames (interleaved L/R 16-bit PCM) mixing all
  /// active voices with constant-power stereo panning and soft limiting.
  Int16List mixStereoFrames(int frameCount) {
    final acc = Float32List(frameCount * 2);
    final finished = <int>[];

    for (final v in _voices.values) {
      if (v.paused || v.stopped) continue;
      final src = v.buffer.samples;
      final srcCh = v.buffer.channels;
      final srcFrames = v.buffer.frameCount;
      if (srcFrames == 0) {
        finished.add(v.id);
        continue;
      }

      final rateRatio = (v.buffer.sampleRate / sampleRate) * v.pitch;
      final angle = (v.pan + 1.0) * 0.25 * math.pi; // constant-power pan
      final gainL = math.cos(angle) * v.volume;
      final gainR = math.sin(angle) * v.volume;

      for (var i = 0; i < frameCount; i++) {
        var idx = v.cursor.floor();
        if (idx >= srcFrames) {
          if (v.loop) {
            v.cursor %= srcFrames;
            idx = v.cursor.floor();
          } else {
            finished.add(v.id);
            break;
          }
        }
        final sampleL = src[idx * srcCh] / 32768.0;
        final sampleR = srcCh > 1 ? src[idx * srcCh + 1] / 32768.0 : sampleL;
        final mono = (sampleL + sampleR) * 0.5;
        acc[i * 2] += mono * gainL;
        acc[i * 2 + 1] += mono * gainR;
        v.cursor += rateRatio;
      }
    }

    for (final id in finished) {
      _voices.remove(id);
    }

    final out = Int16List(frameCount * 2);
    for (var i = 0; i < out.length; i++) {
      // Soft tanh-like limiter prevents harsh digital clipping
      final x = acc[i];
      final limited = x / (1.0 + x.abs() * 0.25);
      out[i] = (limited.clamp(-1.0, 1.0) * 32767.0).round();
    }
    return out;
  }
}

/// 100% custom IMA-ADPCM 4:1 Voice Compressor & Decompressor (zero external
/// dependencies). Compresses 16-bit PCM voice packets to 4 bits/sample.
class VoiceCodecAdpcm {
  const VoiceCodecAdpcm._();

  static const List<int> _indexTable = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
  ];

  static const List<int> _stepTable = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37,
    41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
    190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
    7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500,
    20350, 22385, 24623, 27086, 29794, 32767,
  ];

  /// Encodes 16-bit mono PCM into a compact header (3 bytes) + 4-bit nibbles.
  static Uint8List encode(Int16List pcm) {
    if (pcm.isEmpty) return Uint8List(0);
    var predictor = pcm[0];
    var stepIndex = 0;
    final n = pcm.length;
    final nibbleCount = n - 1;
    final out = Uint8List(4 + ((nibbleCount + 1) >> 1));
    final bd = ByteData.sublistView(out);
    bd.setInt16(0, predictor, Endian.little);
    out[2] = stepIndex;
    out[3] = nibbleCount & 1; // odd-sample flag

    var outByte = 4;
    var highNibble = false;
    var curByte = 0;

    for (var i = 1; i < n; i++) {
      final step = _stepTable[stepIndex];
      var diff = pcm[i] - predictor;
      var code = 0;
      if (diff < 0) {
        code = 8;
        diff = -diff;
      }
      var vpdiff = step >> 3;
      if (diff >= step) {
        code |= 4;
        diff -= step;
        vpdiff += step;
      }
      final step2 = step >> 1;
      if (diff >= step2) {
        code |= 2;
        diff -= step2;
        vpdiff += step2;
      }
      final step4 = step >> 2;
      if (diff >= step4) {
        code |= 1;
        vpdiff += step4;
      }

      if ((code & 8) != 0) {
        predictor -= vpdiff;
      } else {
        predictor += vpdiff;
      }
      predictor = predictor.clamp(-32768, 32767);
      stepIndex = (stepIndex + _indexTable[code]).clamp(0, 88);

      if (!highNibble) {
        curByte = code & 0x0F;
        highNibble = true;
      } else {
        out[outByte++] = curByte | ((code & 0x0F) << 4);
        highNibble = false;
      }
    }
    if (highNibble) {
      out[outByte] = curByte;
    }
    return out;
  }

  /// Decodes an IMA-ADPCM packet back to 16-bit mono PCM.
  static Int16List decode(Uint8List packet) {
    if (packet.length < 4) return Int16List(0);
    final bd = ByteData.sublistView(packet);
    var predictor = bd.getInt16(0, Endian.little);
    var stepIndex = packet[2].clamp(0, 88);
    final odd = packet[3] == 1;
    final payloadBytes = packet.length - 4;
    final totalNibbles = payloadBytes * 2 - (odd ? 1 : 0);
    final out = Int16List(1 + totalNibbles);
    out[0] = predictor;

    var outIdx = 1;
    for (var b = 0; b < payloadBytes; b++) {
      final byte = packet[4 + b];
      for (var shift = 0; shift <= 4; shift += 4) {
        if (outIdx >= out.length) break;
        final code = (byte >> shift) & 0x0F;
        final step = _stepTable[stepIndex];
        var vpdiff = step >> 3;
        if ((code & 4) != 0) vpdiff += step;
        if ((code & 2) != 0) vpdiff += step >> 1;
        if ((code & 1) != 0) vpdiff += step >> 2;
        if ((code & 8) != 0) {
          predictor -= vpdiff;
        } else {
          predictor += vpdiff;
        }
        predictor = predictor.clamp(-32768, 32767);
        stepIndex = (stepIndex + _indexTable[code]).clamp(0, 88);
        out[outIdx++] = predictor;
      }
    }
    return out;
  }
}

/// Voice Activity Detector (VAD) + Noise Gate so silence isn't sent over network.
class VoiceActivityDetector {
  VoiceActivityDetector({
    this.rmsThreshold = 0.02,
    this.hangoverFrames = 8,
  });

  double rmsThreshold;
  int hangoverFrames;
  int _hangover = 0;

  double computeRms(Int16List pcm) {
    if (pcm.isEmpty) return 0.0;
    var sum = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      final s = pcm[i] / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / pcm.length);
  }

  bool isSpeech(Int16List pcm) {
    final rms = computeRms(pcm);
    if (rms >= rmsThreshold) {
      _hangover = hangoverFrames;
      return true;
    }
    if (_hangover > 0) {
      _hangover--;
      return true;
    }
    return false;
  }
}

/// Networked voice packet carrying compressed IMA-ADPCM audio & metadata.
class VoicePacket {
  VoicePacket({
    required this.senderId,
    required this.sequence,
    required this.channel,
    required this.adpcmPayload,
    this.sampleRate = 16000,
  });

  final String senderId;
  final int sequence;
  final String channel; // 'global', 'team', 'proximity'
  final Uint8List adpcmPayload;
  final int sampleRate;
}

/// Reorders out-of-order voice packets and handles packet loss smoothly.
class VoiceJitterBuffer {
  VoiceJitterBuffer({this.maxPackets = 12});

  final int maxPackets;
  final Map<int, VoicePacket> _queue = {};
  int? _nextSeq;

  void push(VoicePacket pkt) {
    _nextSeq ??= pkt.sequence;
    if (pkt.sequence < _nextSeq!) return; // late duplicate
    _queue[pkt.sequence] = pkt;
    if (_queue.length > maxPackets) {
      final oldest = _queue.keys.reduce(math.min);
      _queue.remove(oldest);
      if (_nextSeq! <= oldest) _nextSeq = oldest + 1;
    }
  }

  VoicePacket? popNext() {
    if (_nextSeq == null) return null;
    final pkt = _queue.remove(_nextSeq);
    if (pkt != null) {
      _nextSeq = _nextSeq! + 1;
      return pkt;
    }
    if (_queue.isNotEmpty) {
      final minSeq = _queue.keys.reduce(math.min);
      if (minSeq - _nextSeq! >= 2) {
        _nextSeq = minSeq;
        return popNext();
      }
    }
    return null;
  }
}

/// Full Multiplayer Voice Chat (VoIP) Manager supporting Team, Global, and
/// 3D Proximity Spatial Voice (distance falloff + left/right stereo panning),
/// Push-To-Talk, VAD, Mute, Deafen, and zero-dependency IMA-ADPCM compression.
class VoiceChatManager {
  VoiceChatManager({
    required this.localPlayerId,
    this.sampleRate = 16000,
    this.proximityMaxDistance = 30.0,
    this.proximityMinDistance = 2.0,
  });

  final String localPlayerId;
  final int sampleRate;
  double proximityMaxDistance;
  double proximityMinDistance;

  bool micMuted = false;
  bool deafened = false;
  bool pushToTalk = false;
  bool pushToTalkHeld = false;
  double voiceVolume = 1.0;
  String activeChannel = 'proximity';

  final VoiceActivityDetector vad = VoiceActivityDetector();
  final Set<String> mutedPlayers = {};
  final Map<String, VoiceJitterBuffer> _buffers = {};
  final Map<String, Vector3> _playerPositions = {};

  Vector3 listenerPosition = Vector3.zero();
  Vector3 listenerRight = Vector3(1, 0, 0);

  int _outgoingSeq = 0;

  void setPlayerPosition(String playerId, Vector3 pos) {
    _playerPositions[playerId] = pos.clone();
  }

  void setListenerPose(Vector3 position, Vector3 right) {
    listenerPosition = position.clone();
    listenerRight = right.length > 0 ? right.normalized() : Vector3(1, 0, 0);
  }

  /// Processes a captured mic PCM frame. Returns a compressed [VoicePacket] to
  /// send over your network transport, or `null` when muted / silent.
  VoicePacket? captureMicFrame(Int16List pcm) {
    if (micMuted) return null;
    if (pushToTalk && !pushToTalkHeld) return null;
    if (!pushToTalk && !vad.isSpeech(pcm)) return null;
    return VoicePacket(
      senderId: localPlayerId,
      sequence: _outgoingSeq++,
      channel: activeChannel,
      adpcmPayload: VoiceCodecAdpcm.encode(pcm),
      sampleRate: sampleRate,
    );
  }

  /// Feeds a received remote [VoicePacket] into that speaker's jitter buffer.
  void receivePacket(VoicePacket pkt) {
    if (deafened || pkt.senderId == localPlayerId) return;
    if (mutedPlayers.contains(pkt.senderId)) return;
    _buffers.putIfAbsent(pkt.senderId, () => VoiceJitterBuffer()).push(pkt);
  }

  /// Mixes the next [frameCount] stereo 16-bit PCM frames of all active remote
  /// speakers, applying 3D proximity attenuation and stereo panning.
  Int16List mixIncomingStereo(int frameCount) {
    final out = Int16List(frameCount * 2);
    if (deafened) return out;
    final acc = Float32List(frameCount * 2);

    for (final entry in _buffers.entries) {
      final speakerId = entry.key;
      final pkt = entry.value.popNext();
      if (pkt == null) continue;

      final pcm = VoiceCodecAdpcm.decode(pkt.adpcmPayload);
      var gain = voiceVolume;
      var pan = 0.0;

      if (pkt.channel == 'proximity') {
        final pos = _playerPositions[speakerId];
        if (pos != null) {
          final delta = pos - listenerPosition;
          final dist = delta.length;
          if (dist >= proximityMaxDistance) continue;
          if (dist > proximityMinDistance) {
            final t = (dist - proximityMinDistance) /
                (proximityMaxDistance - proximityMinDistance);
            gain *= (1.0 - t).clamp(0.0, 1.0);
          }
          if (dist > 0.001) {
            pan = (delta.dot(listenerRight) / dist).clamp(-1.0, 1.0);
          }
        }
      }

      final angle = (pan + 1.0) * 0.25 * math.pi;
      final gainL = math.cos(angle) * gain;
      final gainR = math.sin(angle) * gain;
      final n = math.min(frameCount, pcm.length);
      for (var i = 0; i < n; i++) {
        final s = pcm[i] / 32768.0;
        acc[i * 2] += s * gainL;
        acc[i * 2 + 1] += s * gainR;
      }
    }

    for (var i = 0; i < out.length; i++) {
      final x = acc[i];
      final limited = x / (1.0 + x.abs() * 0.25);
      out[i] = (limited.clamp(-1.0, 1.0) * 32767.0).round();
    }
    return out;
  }
}
