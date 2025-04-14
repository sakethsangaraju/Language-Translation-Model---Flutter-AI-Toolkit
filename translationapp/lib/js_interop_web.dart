// This file contains the actual web implementation of JavaScript interop
// It will only be imported in web environments

import 'dart:convert';
import 'dart:developer' as developer;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';
import 'package:crypto/crypto.dart' as crypto;

/// Rolling list of recently played chunk fingerprints.
final List<String> _recentFingerprints = [];
const int _maxFingerprintCount = 100;

/// Track timestamps of last few chunks to detect unusually small chunks
final Map<String, DateTime> _chunkTimestamps = {};
const int _minTimeBetweenSimilarChunksMs =
    300; // Don't play similar chunks less than 300ms apart

// Define JS interop functions
@JS('initWebAudio')
external JSAny? _initWebAudio();

@JS('playPcmAudioStreaming')
external JSAny? _playPcmAudioStreaming(String base64Audio);

/// Try to initialize Web Audio - returns true if successful
bool callInitWebAudio() {
  try {
    // The JavaScript function returns a boolean indicating success
    final result = _initWebAudio();
    final success = result == true;
    developer.log(
      'Web Audio API initialization attempt: ${success ? 'successful' : 'failed'}',
    );
    return success;
  } catch (e) {
    developer.log('Error initializing Web Audio API: $e');
    return false;
  }
}

/// Play PCM audio with deduplication to avoid repeated chunks
void callPlayPcmAudio(String base64Audio) {
  try {
    // Decode base64 to raw bytes for fingerprinting
    final bytes = base64Decode(base64Audio);

    // Skip very small chunks (likely silent or incomplete)
    if (bytes.length < 100) {
      developer.log('Skipping very small audio chunk (${bytes.length} bytes)');
      return;
    }

    // Compute full MD5 hash of the entire chunk
    final fullDigest = crypto.md5.convert(bytes).toString();

    // Check if we've played this exact chunk recently
    if (_recentFingerprints.contains(fullDigest)) {
      developer.log(
        'Skipping duplicate audio chunk (fingerprint = $fullDigest)',
      );
      return;
    }

    // Compute partial fingerprints from different parts of the audio
    // This helps detect chunks that are mostly the same but with slight differences
    final partialFingerprints = _computePartialFingerprints(bytes);

    // Check if we've played a very similar chunk recently
    final now = DateTime.now();
    for (final partialDigest in partialFingerprints) {
      final lastPlayed = _chunkTimestamps[partialDigest];
      if (lastPlayed != null) {
        final timeSinceLastPlayed = now.difference(lastPlayed).inMilliseconds;
        if (timeSinceLastPlayed < _minTimeBetweenSimilarChunksMs) {
          developer.log(
            'Skipping similar audio chunk played ${timeSinceLastPlayed}ms ago',
          );
          return;
        }
      }
      // Update timestamp for this partial fingerprint
      _chunkTimestamps[partialDigest] = now;
    }

    // If not a duplicate, add the fingerprint to our tracking list
    _recentFingerprints.add(fullDigest);
    if (_recentFingerprints.length > _maxFingerprintCount) {
      _recentFingerprints.removeAt(0); // Remove oldest fingerprint
    }

    // Clean up timestamp map if it gets too large
    if (_chunkTimestamps.length > _maxFingerprintCount * 3) {
      // Get entries, sort them, and take the most recent ones
      final entries = _chunkTimestamps.entries.toList();
      entries.sort((a, b) => b.value.compareTo(a.value)); // Sort by most recent

      final keysToKeep =
          entries
              .take(
                _maxFingerprintCount * 2,
              ) // Keep twice as many as full fingerprints
              .map((e) => e.key)
              .toList();

      _chunkTimestamps.removeWhere((key, _) => !keysToKeep.contains(key));
    }

    // Call the JavaScript streaming function with the base64 audio
    _playPcmAudioStreaming(base64Audio);
    developer.log(
      'Audio chunk passed to Web Audio API (fingerprint = $fullDigest, length = ${bytes.length})',
    );
  } catch (e) {
    developer.log('Error streaming audio on web: $e');
  }
}

/// Compute multiple fingerprints from different parts of the audio
/// This helps detect chunks that are mostly the same but with slight differences
List<String> _computePartialFingerprints(List<int> bytes) {
  final result = <String>[];
  final length = bytes.length;

  // Skip if the chunk is too small
  if (length < 1000) {
    return result;
  }

  // Take samples from different parts of the audio
  final positions = [
    0, // Start
    length ~/ 4, // First quarter
    length ~/ 2, // Middle
    (length * 3) ~/ 4, // Third quarter
    length - 500, // End (minus a small offset)
  ];

  for (final pos in positions) {
    // Ensure we don't go out of bounds
    if (pos < 0 || pos + 500 > length) continue;

    // Take a 500-byte sample and hash it
    final sample = bytes.sublist(pos, pos + 500);
    final digest = crypto.md5.convert(sample).toString();
    result.add('${pos}_$digest');
  }

  return result;
}

@JS('initWebAudio')
external JSBoolean? initWebAudio();
