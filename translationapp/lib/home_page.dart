import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:typed_data';
// Import flutter_pcm_sound only for non-web platforms
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart'
    if (dart.library.html) 'web_dummy.dart';
import 'package:audio_session/audio_session.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
// Only import js for web platforms
import 'js_interop.dart';

// Define theme colors based on NativeFlow logo (Assuming NativeFlowTheme class exists)
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

  // --- Playback State ---
  // Use _playbackPcmData for the Android callback feeding mechanism
  final List<int> _playbackPcmData = [];
  // Temporary buffer for accumulating chunks before playing (used by both platforms)
  final List<int> _tempPcmBuffer = [];
  // Track if the PCM player (Android) is set up
  bool _isPcmPlayerSetup = false; // Renamed from isSetup for clarity
  // --- End Playback State ---

  // Add a timer to detect silence in audio stream
  Timer? _audioSilenceTimer;

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
    _speakingTimeoutTimer?.cancel();

    if (isRecording) stopStream();
    record.dispose();
    channel.sink.close();

    // Dispose FlutterPcmSound resources only if not on web and if setup
    if (!kIsWeb && _isPcmPlayerSetup) {
      try {
        // Now FlutterPcmSound is only referenced inside the non-web block
        FlutterPcmSound.release();
        log('FlutterPcmSound released');
      } catch (e) {
        log('Error releasing FlutterPcmSound: $e');
      }
    }

    super.dispose();
    log('Disposed');
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

  // --- Connection and Initialization ---
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

      // Set up audio and listeners AFTER connection is established
      // Setup PCM Sound only for Android/iOS
      if (!kIsWeb) {
        await _setupPcmSound();
      }
      // Listen for messages regardless of platform
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
      // Use localhost for web development, adjust for production
      return 'ws://localhost:9083';
    } else if (Platform.isAndroid) {
      // Special IP for Android emulator
      return 'ws://10.0.2.2:9083';
    } else {
      // Default for iOS simulator and other platforms
      return 'ws://localhost:9083';
    }
  }

  void _initWebAudio() {
    if (kIsWeb) {
      try {
        // Call our interop layer
        webAudioInitialized = initWebAudio(); // Store the result
        log('Web Audio API initialization attempt: $webAudioInitialized');
      } catch (e) {
        log('Error calling initWebAudio interop: $e');
        webAudioInitialized = false;
      }
    }
  }

  Future<void> _initAudioSession() async {
    if (kIsWeb) return; // Skip for web
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

  // --- Recording Logic ---
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
    if (!mounted) return; // Check if the widget is still in the tree
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
      if (mounted) _showPermissionAlert(context); // Show an alert
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
            if (mounted) setState(() => isRecording = false);
            sendTimer?.cancel();
            silenceTimer?.cancel();
          },
          onDone: () {
            log('Stream done');
            sendTimer?.cancel();
            silenceTimer?.cancel();
            if (audioBuffer.isNotEmpty) sendBufferedAudio();
            if (mounted) setState(() => isRecording = false);
          },
        );
        if (mounted) setState(() => isRecording = true);
      } catch (e) {
        log('Error starting recording stream: $e');
        if (mounted) {
          setState(() => serverResponse = "Error starting recording.");
        }
        return; // Stop if stream fails to start
      }
    } else {
      log(
        'Already recording.',
      ); // Handle case where button is pressed while recording
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
    if (mounted) {
      setState(() => isRecording = false); // Update state when stopped
    }
  }

  // --- Playback Logic ---
  void _listenForAudioStream() {
    channel.stream.listen(
      (message) {
        try {
          var data = jsonDecode(message as String);

          // Handle text messages
          if (data['text'] != null) {
            if (mounted) {
              setState(
                () => serverResponse = "${data['text']}",
              ); // Removed "Text:" prefix
            }
            log('Received text: ${data['text']}');
          }
          // Handle audio_start signal
          else if (data['audio_start'] == true) {
            log('Received audio_start signal - preparing for audio playback');
            if (mounted) {
              setState(() {
                isAiSpeaking = true;
                _tempPcmBuffer.clear(); // Clear temp buffer for new response
                if (!kIsWeb) {
                  // Clear playback buffer for Android callback only when new audio starts
                  _playbackPcmData.clear();
                  log('Cleared Android playback buffer (_playbackPcmData)');
                }
              });
            }
            _lastAudioChunkTime = DateTime.now();
          }
          // Handle audio chunks - buffer them for later playback
          else if (data['audio'] != null) {
            String base64Audio = data['audio'] as String;

            // Decode and buffer the audio chunk into the temporary buffer
            var pcmBytes = base64Decode(base64Audio);
            _tempPcmBuffer.addAll(pcmBytes);

            // Update last chunk time
            _lastAudioChunkTime = DateTime.now();

            log(
              'Buffered audio chunk: ${pcmBytes.length} bytes, Total temp buffered: ${_tempPcmBuffer.length}',
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

                if (mounted) {
                  setState(() {
                    isAiSpeaking = false;
                  });
                }
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
              _playBufferedAudio(); // This now handles platform specifics
            } else {
              log('Turn complete received, but no audio was buffered.');
              // Even if no audio, mark AI as not speaking
              if (mounted) {
                setState(() {
                  isAiSpeaking = false;
                });
              }
            }

            // Cancel the speaking timeout timer
            _speakingTimeoutTimer?.cancel();

            // Update UI state after a potential delay (adjust if needed)
            // Using a shorter delay or no delay might be fine depending on playback speed
            // Future.delayed(const Duration(milliseconds: 100), () {
            // Ensure state is updated even if buffer was empty
            if (!isAiSpeaking && mounted) {
              setState(() {
                isAiSpeaking = false;
              });
            }

            // });
          }
        } catch (e) {
          log('Decoding error: $e, message: $message');
        }
      },
      onError: (error) {
        log('WebSocket error: $error');
        if (mounted) {
          setState(() {
            connectionStatus = 'Connection error: $error';
            isAiSpeaking = false; // Reset speaking state on error
            isRecording = false; // Reset recording state on error
            isConnecting =
                true; // Attempt to reconnect or indicate disconnected state
          });
        }
        // Optionally attempt reconnection here
        // _initConnection(); // Be careful with immediate reconnection loops
      },
      onDone: () {
        log('WebSocket closed');
        if (mounted) {
          setState(() {
            connectionStatus = 'Connection closed';
            isAiSpeaking = false; // Reset speaking state
            isRecording = false; // Reset recording state
            isConnecting =
                true; // Indicate disconnected state, maybe trigger reconnect button
          });
        }
      },
    );
  }

  // Play all buffered audio using platform-specific method
  void _playBufferedAudio() {
    if (_tempPcmBuffer.isEmpty) return;

    final List<int> audioToPlay = List<int>.from(_tempPcmBuffer);
    _tempPcmBuffer.clear(); // Clear the temporary buffer immediately

    if (kIsWeb) {
      // --- Web Playback ---
      if (!webAudioInitialized) {
        log('Web audio not initialized, attempting now...');
        _initWebAudio(); // Try initializing again
        if (!webAudioInitialized) {
          log('Failed to initialize web audio, cannot play.');
          if (mounted) {
            setState(() => isAiSpeaking = false); // Ensure UI updates
          }
          return;
        }
      }
      // Encode the entire buffer back to base64 and play it via JS interop
      String combinedBase64 = base64Encode(audioToPlay);
      try {
        playWebAudio(combinedBase64); // Call the JS interop function
        log(
          'Combined audio passed to Web Audio API for playback (${audioToPlay.length} bytes)',
        );
      } catch (e) {
        log('Error playing combined audio on web: $e');
      } finally {
        // Assume web playback finishes relatively quickly or handles its own state
        if (mounted) {
          setState(() => isAiSpeaking = false);
        }
      }
    } else {
      // --- Android/iOS Playback (Callback Method) ---
      if (!_isPcmPlayerSetup) {
        log('Android/iOS PCM player not setup, cannot play.');
        if (mounted) {
          setState(() => isAiSpeaking = false); // Ensure UI updates
        }
        return;
      }

      // Add the buffered audio to the playback queue for the callback
      _playbackPcmData.addAll(audioToPlay);
      log(
        'Added ${audioToPlay.length} bytes to Android playback buffer. Total: ${_playbackPcmData.length}',
      );

      // Start playback if not already started (the callback will handle feeding)
      if (!kIsWeb) {
        // Ensure this block is only for non-web
        try {
          FlutterPcmSound.start(); // This call is now guarded by !kIsWeb
          log('Ensured FlutterPcmSound is started for callback.');
        } catch (e) {
          log('Error ensuring FlutterPcmSound start: $e');
        }
      }

      // Note: We don't set isAiSpeaking = false here for Android.
      // It should ideally be set when the _playbackPcmData buffer becomes empty
      // or after a reasonable timeout in the callback/feed mechanism if needed.
      // For simplicity, we might rely on the next 'turn_complete' or timeout for UI update.
      // Or, add logic to _onFeed to set isAiSpeaking = false when _playbackPcmData is empty.
    }
  }

  // Setup FlutterPcmSound for Android/iOS
  Future<void> _setupPcmSound() async {
    // This initial check correctly prevents execution on web
    if (kIsWeb || _isPcmPlayerSetup) return;

    try {
      log('Setting up PCM sound player (Android/iOS)...');
      // These calls are now implicitly guarded by the !kIsWeb check above
      FlutterPcmSound.setFeedCallback(_onFeed);
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
      _isPcmPlayerSetup = true;
      log('PCM sound player initialized successfully (24000Hz)');
    } catch (e) {
      log('PCM Sound setup error: $e');
      _isPcmPlayerSetup = false; // Ensure setup status is correct on error
    }
  }

  // Callback for flutter_pcm_sound (Android/iOS)
  void _onFeed(int remainingFrames) {
    // Add a top-level check for safety, although it should only be called when !kIsWeb
    if (kIsWeb) return;

    // Determine feed size (adjust buffer size as needed, e.g., 4096 or 8192 bytes = 2048 or 4096 frames)
    const int feedSizeBytes = 8000; // 4000 frames (int16) = 8000 bytes
    int feedSizeSamples = feedSizeBytes ~/ 2; // Samples (frames)

    if (_playbackPcmData.isNotEmpty) {
      final int bytesToFeed =
          _playbackPcmData.length > feedSizeBytes
              ? feedSizeBytes
              : _playbackPcmData.length;
      // Ensure bytesToFeed is an even number for Int16 conversion
      final int actualBytesToFeed =
          (bytesToFeed % 2 == 0) ? bytesToFeed : bytesToFeed - 1;

      if (actualBytesToFeed <= 0) {
        log('Feed size became zero or negative, feeding silence.');
        try {
          // Guard PcmArrayInt16 usage
          FlutterPcmSound.feed(
            PcmArrayInt16.fromList(List.filled(feedSizeSamples, 0)),
          );
        } catch (e) {
          log('Error feeding silence (zero/neg size): $e');
        }
        if (_playbackPcmData.isNotEmpty) {
          _playbackPcmData.clear(); // Clear remaining odd byte if any
        }
        if (mounted) {
          setState(
            () => isAiSpeaking = false,
          ); // Buffer empty, stop speaking indicator
        }
        return;
      }

      // Extract the exact number of bytes to feed
      final frameBytes = _playbackPcmData.sublist(0, actualBytesToFeed);
      try {
        // Guard PcmArrayInt16 usage
        FlutterPcmSound.feed(
          PcmArrayInt16(
            bytes: ByteData.view(Uint8List.fromList(frameBytes).buffer),
          ),
        );
        _playbackPcmData.removeRange(0, actualBytesToFeed);
        log(
          'Fed $actualBytesToFeed bytes, remaining: ${_playbackPcmData.length}',
        );
      } catch (e) {
        log('Error feeding PCM frame: $e');
        // Consider clearing buffer or stopping on error?
        _playbackPcmData.clear(); // Clear buffer on feed error
        if (mounted) {
          setState(() => isAiSpeaking = false);
        }
      }
    } else {
      // Buffer is empty, feed silence
      try {
        // Guard PcmArrayInt16 usage
        FlutterPcmSound.feed(
          PcmArrayInt16.fromList(List.filled(feedSizeSamples, 0)),
        );
        log('Fed silence (buffer empty)');
        // If the buffer is empty, the AI is no longer speaking
        if (isAiSpeaking && mounted) {
          setState(() => isAiSpeaking = false);
        }
      } catch (e) {
        log('Error feeding silence (buffer empty): $e');
      }
    }
  }
}

// --- Helper for Dynamic FlutterPcmSound Calls ---
// This avoids direct static calls that cause issues on the web.
// You might place this outside the class or in a separate utility file.
// Note: This is a workaround. Proper conditional imports and platform checks
// are generally preferred.

// We use `as dynamic` directly within the methods where needed,
// avoiding the need for a separate helper class here.
