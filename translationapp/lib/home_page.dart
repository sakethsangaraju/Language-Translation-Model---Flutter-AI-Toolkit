import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:audio_session/audio_session.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
// Only import js for web platforms
import 'js_interop.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late WebSocketChannel channel;
  final record = AudioRecorder();
  bool isRecording = false;
  List<int> audioBuffer = [];
  Timer? sendTimer;
  Timer? silenceTimer;
  String serverResponse = '';
  bool isConnecting = true;
  String connectionStatus = 'Connecting to server...';
  bool webAudioInitialized = false;
  bool isAiSpeaking = false;
  int silentSeconds = 0;

  // Playback
  final List<int> _pcmData = [];
  // New temporary buffer for storing audio chunks until turn_complete
  final List<int> _tempPcmBuffer = [];
  bool isSetup = false;

  // Add a timer to detect silence in audio stream
  Timer? _audioSilenceTimer;
  bool _waitingForMoreAudio = false;
  // Lowering the silence threshold to make audio play faster
  final int _silenceThresholdMs =
      200; // Time to wait for more audio before playing

  // This is an important constant - it helps calculate estimated duration
  // 24000 samples/sec * 2 bytes/sample = 48 bytes per millisecond
  final int _bytesPerMs = 48;

  // Maximum accumulated buffer size before forcing playback
  // This prevents delays if large continuous audio is received
  final int _maxBufferSize = 192000; // ~4 seconds at 24kHz 16-bit mono

  @override
  void initState() {
    super.initState();
    _initConnection();

    // Try to initialize web audio immediately
    if (kIsWeb) {
      _initWebAudio();
    }
  }

  void _initConnection() async {
    setState(() {
      isConnecting = true;
      connectionStatus = 'Connecting to server...';
    });

    try {
      // Initialize audio session for mobile platforms
      if (!kIsWeb) {
        await _initAudioSession();
      }

      // Different WebSocket URL based on platform
      final wsUrl = _getWebSocketUrl();
      log('Connecting to WebSocket URL: $wsUrl');

      channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Set up audio and listeners
      if (!kIsWeb) {
        await _setupPcmSound();
      }
      _listenForAudioStream();

      setState(() {
        isConnecting = false;
        connectionStatus = 'Connected';
      });

      log('WebSocket initialized successfully');
    } catch (e) {
      log('Error initializing connection: $e');
      setState(() {
        isConnecting = false;
        connectionStatus = 'Connection failed: $e';
      });
    }
  }

  String _getWebSocketUrl() {
    if (kIsWeb) {
      // In web, use window.location.hostname instead of 10.0.2.2
      // Since this is a simplification, we'll use localhost by default
      // You would need to adjust this for production to match your server setup
      return 'ws://localhost:9083';
    } else if (Platform.isAndroid) {
      // 10.0.2.2 is special IP for Android emulator to connect to host machine
      return 'ws://10.0.2.2:9083';
    } else {
      // For iOS simulator and other platforms
      return 'ws://localhost:9083';
    }
  }

  void _initWebAudio() {
    if (kIsWeb) {
      try {
        // Call our interop layer
        initWebAudio();
        webAudioInitialized = true;
        log('Web Audio API initialized');
      } catch (e) {
        log('Error initializing Web Audio API: $e');
      }
    }
  }

  void _playWebAudio(String base64Audio) {
    if (kIsWeb) {
      try {
        // Web Audio should try to initialize automatically now
        playWebAudio(base64Audio);
        log('Audio passed to Web Audio API for playback');
      } catch (e) {
        log('Error playing audio on web: $e');
      }
    }
  }

  @override
  void dispose() {
    silenceTimer?.cancel();
    sendTimer?.cancel();
    _audioSilenceTimer?.cancel();
    if (isRecording) stopStream();
    record.dispose();
    channel.sink.close();
    super.dispose();
    log('Disposed');
  }

  Future<void> _initAudioSession() async {
    try {
      log('Initializing audio session...');
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: true,
        ),
      );

      await session.setActive(true);
      log('Audio session initialized and active');
    } catch (e) {
      log('Failed to initialize audio session: $e');
    }
  }

  void _startSilenceDetection() {
    silenceTimer?.cancel();
    silentSeconds = 0;

    silenceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      silentSeconds++;

      if (silentSeconds >= 5) {
        log('5 seconds of silence detected - stopping recording');
        stopRecordingOnly();
        setState(() => isRecording = false);
        silenceTimer?.cancel();
      }
    });
  }

  void sendJsonAudioStream() async {
    if (isConnecting) {
      log('Cannot record while connecting to server');
      return;
    }

    if (isAiSpeaking) {
      log('Cannot start recording while AI is speaking');
      return;
    }

    if (!isRecording && await record.hasPermission()) {
      channel.sink.add(
        jsonEncode({
          "setup": {
            "generation_config": {"language": "en"},
          },
        }),
      );
      log('Config sent');

      final stream = await record.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      audioBuffer.clear();
      sendTimer?.cancel();

      // Start the silence detection timer
      _startSilenceDetection();

      // Send data periodically
      sendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (audioBuffer.isNotEmpty) {
          sendBufferedAudio();
          // Reset the silence timer when we send data
          silentSeconds = 0;
        }
      });

      stream.listen(
        (List<int> chunk) {
          if (chunk.isNotEmpty) {
            audioBuffer.addAll(chunk);
            log('Buffered ${chunk.length} bytes, Total: ${audioBuffer.length}');
            // Reset silence detection since we got audio
            silentSeconds = 0;
          }
        },
        onError: (error) {
          log('Stream error: $error');
          setState(() => isRecording = false);
          sendTimer?.cancel();
          silenceTimer?.cancel();
        },
        onDone: () {
          log('Stream done');
          sendTimer?.cancel();
          silenceTimer?.cancel();
          if (audioBuffer.isNotEmpty) sendBufferedAudio();
          setState(() => isRecording = false);
        },
      );

      setState(() => isRecording = true);
    } else {
      log('Microphone permission denied');
      setState(() => serverResponse = "Microphone permission denied");
    }
  }

  void _listenForAudioStream() {
    channel.stream.listen(
      (message) {
        try {
          var data = jsonDecode(message as String);

          // Handle text messages
          if (data['text'] != null) {
            setState(() => serverResponse = "Text: ${data['text']}");
            log('Received text: ${data['text']}');
          }
          // Handle audio_start signal
          else if (data['audio_start'] == true) {
            log('Received audio_start signal - preparing for audio playback');
            setState(() {
              isAiSpeaking = true;
              _tempPcmBuffer.clear(); // Clear any leftover audio
            });
          }
          // Handle audio chunks
          else if (data['audio'] != null) {
            String base64Audio = data['audio'] as String;
            var pcmBytes = base64Decode(base64Audio);
            log('Received audio: ${pcmBytes.length} bytes');

            // Add the audio data to the temporary buffer
            _tempPcmBuffer.addAll(pcmBytes);
            log(
              'Added ${pcmBytes.length} bytes to temp buffer, total: ${_tempPcmBuffer.length}',
            );

            // Play immediately if the buffer gets too large
            if (_tempPcmBuffer.length > _maxBufferSize) {
              log(
                'Buffer size exceeded maximum, playing now: ${_tempPcmBuffer.length} bytes',
              );
              _audioSilenceTimer?.cancel();
              _playBufferedAudio();
              return;
            }

            // Reset the silence timer each time we receive audio
            _waitingForMoreAudio = true;
            _audioSilenceTimer?.cancel();
            _audioSilenceTimer = Timer(
              Duration(milliseconds: _silenceThresholdMs),
              () {
                // If we've waited a bit and no more audio has arrived, play what we have
                if (_waitingForMoreAudio && _tempPcmBuffer.isNotEmpty) {
                  log(
                    'Audio silence detected, playing current buffer: ${_tempPcmBuffer.length} bytes',
                  );
                  _playBufferedAudio();
                  _waitingForMoreAudio = false;
                }
              },
            );
          }
          // Handle turn_complete flag
          else if (data['turn_complete'] == true) {
            log('Turn complete signal received');
            _audioSilenceTimer?.cancel();

            // Only play if we haven't already played due to silence detection
            if (_tempPcmBuffer.isNotEmpty) {
              log(
                'Playing final buffered audio on turn_complete: ${_tempPcmBuffer.length} bytes',
              );
              _playBufferedAudio();
            } else {
              setState(() {
                isAiSpeaking = false;
              });
            }
          }
        } catch (e) {
          log('Decoding error: $e, message: $message');
        }
      },
      onError: (error) {
        log('WebSocket error: $error');
        setState(() {
          connectionStatus = 'Connection error: $error';
          isAiSpeaking = false;
        });
      },
      onDone: () {
        log('WebSocket closed');
        setState(() {
          connectionStatus = 'Connection closed';
          isAiSpeaking = false;
        });
      },
    );
  }

  Future<void> _setupPcmSound() async {
    if (kIsWeb) return; // Skip for web platform

    try {
      if (!isSetup) {
        log('Setting up PCM sound player...');
        FlutterPcmSound.setFeedCallback(_onFeed);
        // Match the sample rate with Gemini's output (usually 24000Hz)
        // This is different from the recording sample rate (16000Hz) but that's expected
        await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
        log('PCM sound setup complete with sample rate 24000Hz');
        isSetup = true;
        log('PCM sound player initialized successfully');
      }
    } catch (e) {
      log('PCM Sound setup error: $e');
    }
  }

  void _onFeed(int remainingFrames) {
    if (kIsWeb) return; // Skip for web platform

    if (_pcmData.isNotEmpty) {
      final feedSize = _pcmData.length > 8000 ? 8000 : _pcmData.length;
      final frame = _pcmData.sublist(0, feedSize);
      try {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(frame));
        _pcmData.removeRange(0, feedSize);
        log('Fed $feedSize samples, remaining: ${_pcmData.length}');
      } catch (e) {
        log('Error feeding PCM frame: $e');
      }
    } else {
      try {
        FlutterPcmSound.feed(
          PcmArrayInt16.fromList(List.filled(8000, 0)),
        ); // Feed silence if no data
        log('Fed silence');
      } catch (e) {
        log('Error feeding silence: $e');
      }
    }
  }

  void sendBufferedAudio() {
    if (audioBuffer.isNotEmpty) {
      String base64Audio = base64Encode(audioBuffer);
      channel.sink.add(
        jsonEncode({
          "realtime_input": {
            "media_chunks": [
              {"mime_type": "audio/pcm", "data": base64Audio},
            ],
          },
        }),
      );
      log('Sent ${audioBuffer.length} bytes');
      audioBuffer.clear();
    }
  }

  void stopStream() async {
    silenceTimer?.cancel();
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();
    channel.sink.close();
    log('Stream & WebSocket closed');
  }

  void stopRecordingOnly() async {
    silenceTimer?.cancel();
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();
    log('Recording stopped');
  }

  // Play the buffered audio
  void _playBufferedAudio() {
    if (_tempPcmBuffer.isEmpty) return;

    // Calculate estimated duration for UI updates
    final estimatedDurationMs = _tempPcmBuffer.length ~/ _bytesPerMs;
    log('Estimated audio duration: ${estimatedDurationMs}ms');

    if (kIsWeb) {
      // For web, encode the entire buffer as base64 and play it
      String fullBase64Audio = base64Encode(_tempPcmBuffer);
      _playWebAudio(fullBase64Audio);
    } else {
      // For mobile, add the complete buffer to the playback buffer
      _pcmData.addAll(_tempPcmBuffer);

      if (!isSetup) {
        log('Setting up PCM sound for the first time');
        _setupPcmSound();
      } else {
        log('Feeding complete PCM data to sound player');
        try {
          FlutterPcmSound.feed(
            PcmArrayInt16(
              bytes: ByteData.view(Uint8List.fromList(_tempPcmBuffer).buffer),
            ),
          );
          log('Complete PCM data fed successfully');
        } catch (e) {
          log('Error feeding complete PCM data: $e');
        }
      }
    }

    // Set a timer to mark when the AI is done speaking (estimated)
    Future.delayed(Duration(milliseconds: estimatedDurationMs), () {
      setState(() {
        isAiSpeaking = false;
      });
    });

    // Clear the temporary buffer after playing
    _tempPcmBuffer.clear();
  }

  Widget _recordingButton() {
    return FloatingActionButton(
      onPressed:
          isConnecting || isAiSpeaking
              ? null // Disable the button while connecting or AI is speaking
              : () async {
                if (isRecording) {
                  stopRecordingOnly();
                  setState(() => isRecording = false);
                } else {
                  sendJsonAudioStream();
                }
              },
      backgroundColor:
          isRecording
              ? Colors.red
              : isAiSpeaking
              ? Colors.deepPurple
              : Theme.of(context).primaryColor,
      child: Icon(
        isRecording
            ? Icons.stop
            : isAiSpeaking
            ? Icons.hearing
            : Icons.mic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Flow: The Live Translation App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isConnecting) const CircularProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                isConnecting
                    ? connectionStatus
                    : (serverResponse.isNotEmpty
                        ? serverResponse
                        : isAiSpeaking
                        ? 'Gemini is speaking...'
                        : isRecording
                        ? 'Listening...'
                        : 'Press microphone to start speaking'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight:
                      isAiSpeaking || isRecording
                          ? FontWeight.bold
                          : FontWeight.normal,
                ),
              ),
            ),
            if (isRecording)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.mic,
                      color: Color.fromARGB(255, 46, 13, 231),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Recording will auto-stop after 5 seconds of silence',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: _recordingButton(),
    );
  }
}
