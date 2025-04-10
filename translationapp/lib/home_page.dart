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

// Define theme colors based on NativeFlow logo
class NativeFlowTheme {
  static const Color primaryBlue = Color(0xFF4D96FF);
  static const Color accentPurple = Color(0xFF5C33FF);
  static const Color lightBlue = Color(0xFF8BC7FF);
  static const Color backgroundGrey = Color(0xFFF9FAFC);
  static const Color textDark = Color(0xFF2D3748);

  // Gradient for background and buttons
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryBlue, accentPurple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
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

  // Animation controllers
  late AnimationController _logoAnimationController;
  late AnimationController _buttonScaleController;
  late AnimationController _buttonSlideController;
  late AnimationController _statusAnimationController;
  late AnimationController _micIconController;
  late AnimationController _speakingAnimationController;
  late AnimationController _progressAnimationController;

  // Animations
  late Animation<double> _logoFadeAnimation;
  late Animation<Offset> _logoSlideAnimation;
  late Animation<double> _buttonScaleAnimation;
  late Animation<Offset> _buttonSlideAnimation;
  late Animation<double> _statusFadeAnimation;
  late Animation<Offset> _statusSlideAnimation;
  late Animation<double> _micIconScaleAnimation;
  late Animation<double> _speakingScaleAnimation;
  late Animation<double> _progressFadeAnimation;

  // Playback
  final List<int> _pcmData = [];
  // New temporary buffer for storing audio chunks until turn_complete
  final List<int> _tempPcmBuffer = [];
  bool isSetup = false;

  // Add a timer to detect silence in audio stream
  Timer? _audioSilenceTimer;
  final bool _waitingForMoreAudio = false;
  // Lowering the silence threshold to make audio play faster
  final int _silenceThresholdMs =
      200; // Time to wait for more audio before playing

  // This is an important constant - it helps calculate estimated duration
  // 24000 samples/sec * 2 bytes/sample = 48 bytes per millisecond
  final int _bytesPerMs = 48;

  // Maximum accumulated buffer size before forcing playback
  // This prevents delays if large continuous audio is received
  final int _maxBufferSize = 192000; // ~4 seconds at 24kHz 16-bit mono

  // Add a timeout timer for audio streaming
  Timer? _speakingTimeoutTimer;
  DateTime? _lastAudioChunkTime;

  @override
  void initState() {
    super.initState();

    // Initialize animation controllers
    _logoAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _buttonScaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _buttonSlideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _statusAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _micIconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _speakingAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _progressAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    // Set up animations
    _logoFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoAnimationController, curve: Curves.easeOut),
    );

    _logoSlideAnimation = Tween<Offset>(
      begin: const Offset(-0.2, 0.0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _logoAnimationController,
        curve: Curves.easeOutQuad,
      ),
    );

    _buttonScaleAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(
        parent: _buttonScaleController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _buttonSlideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.5),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _buttonSlideController,
        curve: Curves.easeOutQuad,
      ),
    );

    _statusFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _statusAnimationController,
        curve: Curves.easeOut,
      ),
    );

    _statusSlideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.2),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _statusAnimationController,
        curve: Curves.easeOutQuad,
      ),
    );

    _micIconScaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _micIconController, curve: Curves.easeInOut),
    );

    _speakingScaleAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(
        parent: _speakingAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _progressFadeAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _progressAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    // Start animations
    _logoAnimationController.forward();
    _buttonSlideController.forward();
    _statusAnimationController.forward();

    // Add a listener to update AI speaking status after audio chunks stop coming
    // This ensures UI updates if we don't get a turn_complete signal
    _speakingTimeoutTimer = Timer(Duration.zero, () {});

    _initConnection();

    // Try to initialize web audio immediately
    if (kIsWeb) {
      _initWebAudio();
    }
  }

  @override
  void dispose() {
    // Dispose animation controllers
    _logoAnimationController.dispose();
    _buttonScaleController.dispose();
    _buttonSlideController.dispose();
    _statusAnimationController.dispose();
    _micIconController.dispose();
    _speakingAnimationController.dispose();
    _progressAnimationController.dispose();

    silenceTimer?.cancel();
    sendTimer?.cancel();
    _audioSilenceTimer?.cancel();
    if (isRecording) stopStream();
    record.dispose();
    channel.sink.close();
    super.dispose();
    log('Disposed');
    _speakingTimeoutTimer?.cancel();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset status animation when message changes
    _statusAnimationController.reset();
    _statusAnimationController.forward();
  }

  Widget _recordingButton() {
    return SlideTransition(
      position: _buttonSlideAnimation,
      child: ScaleTransition(
        scale:
            isRecording || isAiSpeaking
                ? _buttonScaleAnimation
                : const AlwaysStoppedAnimation(1.0),
        child: FloatingActionButton(
          onPressed:
              isConnecting || isAiSpeaking
                  ? null
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
                  ? NativeFlowTheme.accentPurple
                  : NativeFlowTheme.primaryBlue,
          child: Icon(
            isRecording
                ? Icons.stop
                : isAiSpeaking
                ? Icons.hearing
                : Icons.mic,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return FadeTransition(
      opacity: _logoFadeAnimation,
      child: SlideTransition(
        position: _logoSlideAnimation,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Native',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: NativeFlowTheme.primaryBlue,
              ),
            ),
            Text(
              'Flow',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: NativeFlowTheme.accentPurple,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusMessage() {
    final message =
        isConnecting
            ? connectionStatus
            : (serverResponse.isNotEmpty
                ? serverResponse
                : isAiSpeaking
                ? 'Gemini is speaking...'
                : isRecording
                ? 'Listening...'
                : 'Press microphone to start speaking');

    final textColor =
        isAiSpeaking
            ? NativeFlowTheme.accentPurple
            : isRecording
            ? NativeFlowTheme.primaryBlue
            : NativeFlowTheme.textDark;

    return FadeTransition(
      opacity: _statusFadeAnimation,
      child: SlideTransition(
        position: _statusSlideAnimation,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(13),
                blurRadius: 10,
                spreadRadius: 0,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight:
                  isAiSpeaking || isRecording
                      ? FontWeight.bold
                      : FontWeight.normal,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Reset status animation when building with new status
    if (_statusAnimationController.status == AnimationStatus.completed) {
      _statusAnimationController.reset();
      _statusAnimationController.forward();
    }

    return Scaffold(
      backgroundColor: NativeFlowTheme.backgroundGrey,
      appBar: AppBar(
        title: _buildLogo(),
        elevation: 0,
        backgroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, NativeFlowTheme.backgroundGrey],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isConnecting)
                FadeTransition(
                  opacity: _progressFadeAnimation,
                  child: const CircularProgressIndicator(),
                ),

              Padding(
                padding: const EdgeInsets.all(20.0),
                child: _buildStatusMessage(),
              ),

              if (isRecording)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: FadeTransition(
                    opacity: const AlwaysStoppedAnimation(1.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(
                          scale: _micIconScaleAnimation,
                          child: Icon(
                            Icons.mic,
                            color: NativeFlowTheme.primaryBlue,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Recording will auto-stop after 5 seconds of silence',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (isAiSpeaking)
                ScaleTransition(
                  scale: _speakingScaleAnimation,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(50),
                      color: NativeFlowTheme.accentPurple.withAlpha(26),
                    ),
                    child: Icon(
                      Icons.hearing,
                      color: NativeFlowTheme.accentPurple,
                      size: 28,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: _recordingButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // Include the remaining methods from the original file
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
      // 10.0.2.2 special IP for Android emulator to connect to host machine
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
        playWebAudio(base64Audio);
        log('Audio passed to Web Audio API for playback');
      } catch (e) {
        log('Error playing audio on web: $e');
      }
    }
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

  // Helper method to show permission alert with option to open settings
  void _showPermissionAlert(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Microphone Permission Required'),
          content: const Text(
            'This app needs microphone access to record audio. '
            'Please enable microphone access in your device settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  // Open app settings - this will work for both iOS and Android
  void _openAppSettings() async {
    if (kIsWeb) return; // Not applicable for web

    try {
      // You would typically use a plugin like app_settings or permission_handler
      // For this example, we'll just log the action
      log('Opening app settings (would normally use app_settings package)');

      // If you add the package, the code would look like:
      // import 'package:app_settings/app_settings.dart';
      // AppSettings.openAppSettings();
    } catch (e) {
      log('Error opening settings: $e');
    }
  }

  void sendJsonAudioStream() async {
    if (isConnecting || isAiSpeaking) {
      log('Cannot record while connecting or AI speaking');
      return;
    }

    // --- Permission Check ---
    bool hasPermission = await record.hasPermission();
    if (!hasPermission) {
      log('Microphone permission not granted');

      // Show an alert with option to open settings
      _showPermissionAlert(context);
      return; // Don't proceed if permission is denied
    }
    // --- End Permission Check ---

    // Proceed with recording ONLY if permission is granted
    if (!isRecording) {
      channel.sink.add(
        jsonEncode({
          "setup": {
            "generation_config": {"language": "en"},
          },
        }),
      );
      log('Config sent');

      try {
        // Add try-catch around startStream
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
              log(
                'Buffered ${chunk.length} bytes, Total: ${audioBuffer.length}',
              );
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
      } catch (e) {
        log('Error starting recording stream: $e');
        setState(() => serverResponse = "Error starting recording.");
        return; // Stop if stream fails to start
      }
    } else {
      log(
        'Already recording.',
      ); // Handle case where button is pressed while recording
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
            _lastAudioChunkTime = DateTime.now();
          }
          // Handle audio chunks - buffer them for later playback
          else if (data['audio'] != null) {
            String base64Audio = data['audio'] as String;

            // Decode and buffer the audio chunk instead of playing immediately
            var pcmBytes = base64Decode(base64Audio);
            _tempPcmBuffer.addAll(pcmBytes);

            // Update last chunk time
            _lastAudioChunkTime = DateTime.now();

            log(
              'Buffered audio: ${pcmBytes.length} bytes, Total buffered: ${_tempPcmBuffer.length}',
            );

            // Reset speaking timeout - if we stop receiving chunks for 1.5 seconds, assume speaking is done
            _speakingTimeoutTimer?.cancel();
            _speakingTimeoutTimer = Timer(const Duration(milliseconds: 1500), () {
              if (isAiSpeaking &&
                  _lastAudioChunkTime != null &&
                  DateTime.now()
                          .difference(_lastAudioChunkTime!)
                          .inMilliseconds >
                      1400) {
                log(
                  'No audio chunks received for 1.5 seconds, assuming AI is done speaking',
                );

                // If we haven't received a turn_complete but we have buffered audio,
                // play the buffered audio now
                if (_tempPcmBuffer.isNotEmpty) {
                  log(
                    'Playing buffered audio after timeout (${_tempPcmBuffer.length} bytes)',
                  );
                  _playBufferedAudio();
                }

                setState(() {
                  isAiSpeaking = false;
                });
              }
            });
          }
          // Handle turn_complete flag - play all buffered audio
          else if (data['turn_complete'] == true) {
            log('Turn complete signal received');

            // Play the entire buffered audio when the turn is complete
            if (_tempPcmBuffer.isNotEmpty) {
              log(
                'Turn complete: Playing buffered audio (${_tempPcmBuffer.length} bytes)',
              );
              _playBufferedAudio();
            }

            // Cancel the speaking timeout timer
            _speakingTimeoutTimer?.cancel();

            // Update UI state after a short delay to ensure all audio is played
            Future.delayed(const Duration(milliseconds: 500), () {
              setState(() {
                isAiSpeaking = false;
              });
            });
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

  // New helper method to play all buffered audio
  void _playBufferedAudio() {
    if (_tempPcmBuffer.isEmpty) return;

    if (kIsWeb) {
      // For web, encode the entire buffer back to base64 and play it
      String combinedBase64 = base64Encode(_tempPcmBuffer);
      _playCombinedWebAudio(combinedBase64);
    } else {
      // For mobile, ensure PCM player is ready
      if (!isSetup) {
        _setupPcmSound().then((_) {
          // Feed the entire buffered data at once
          _feedAudioData(List<int>.from(_tempPcmBuffer));
        });
      } else {
        // Feed the entire buffered data at once
        _feedAudioData(List<int>.from(_tempPcmBuffer));
      }
    }

    // Clear the buffer after playing
    _tempPcmBuffer.clear();
  }

  // New helper method for web to play combined audio
  void _playCombinedWebAudio(String base64Audio) {
    if (kIsWeb) {
      try {
        // Using existing web audio playback function
        playWebAudio(base64Audio);
        log('Combined audio passed to Web Audio API for playback');
      } catch (e) {
        log('Error playing combined audio on web: $e');
      }
    }
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

  // New helper method to directly feed audio data to the audio player
  void _feedAudioData(List<int> pcmBytes) {
    try {
      FlutterPcmSound.feed(
        PcmArrayInt16(
          bytes: ByteData.view(Uint8List.fromList(pcmBytes).buffer),
        ),
      );
      log('PCM data fed directly: ${pcmBytes.length} bytes');
    } catch (e) {
      log('Error feeding PCM data: $e');
    }
  }
}
