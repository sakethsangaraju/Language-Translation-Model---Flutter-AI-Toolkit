import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart'; // Import SoLoud
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_animate/flutter_animate.dart'; // Keep for animations
import 'package:path_provider/path_provider.dart';

// Define theme colors (assuming NativeFlowTheme class exists)
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
  List<int> audioBuffer = []; // Buffer for recording
  Timer? sendTimer;
  Timer? silenceTimer;
  String serverResponse = '';
  bool isConnecting = true;
  String connectionStatus = 'Connecting to server...';
  bool isAiSpeaking = false;
  int silentSeconds = 0;

  // Animation controllers (Keep all animation logic)
  late AnimationController _logoAnimationController;
  late AnimationController _buttonScaleController;
  late AnimationController _buttonSlideController;
  late AnimationController _statusAnimationController;
  late AnimationController _micIconController;
  late AnimationController _speakingAnimationController;
  late AnimationController _progressAnimationController;

  // Animations (Keep all animation logic)
  late Animation<double> _logoFadeAnimation;
  late Animation<Offset> _logoSlideAnimation;
  late Animation<double> _buttonScaleAnimation;
  late Animation<Offset> _buttonSlideAnimation;
  late Animation<double> _statusFadeAnimation;
  late Animation<Offset> _statusSlideAnimation;
  late Animation<double> _micIconScaleAnimation;
  late Animation<double> _speakingScaleAnimation;
  late Animation<double> _progressFadeAnimation;

  // --- Playback State (Using flutter_soloud) ---
  final List<int> _pcmBuffer =
      []; // Buffer for incoming audio bytes from server
  AudioSource? currentSound;
  StreamSubscription? _audioEventSubscription;
  SoundHandle? _currentSoundHandle; // To track the currently playing sound

  // Add a timeout timer for audio streaming
  Timer? _speakingTimeoutTimer;
  DateTime? _lastAudioChunkTime;

  @override
  void initState() {
    super.initState();

    // Initialize animation controllers (Keep existing animation init)
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

    // Set up animations (Keep existing animation setup)
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

    // Start animations (Keep existing animation start)
    _logoAnimationController.forward();
    _buttonSlideController.forward();
    _statusAnimationController.forward();

    // Timer for speaking timeout
    _speakingTimeoutTimer = Timer(
      Duration.zero,
      () {},
    ); // Initialize dummy timer

    // Set initial state - no automatic audio initialization
    setState(() {
      isConnecting = false;
      connectionStatus = 'Ready to start';
    });
  }

  Future<void> _initSoLoud() async {
    setState(() {
      isConnecting = true;
      connectionStatus = 'Initializing Audio Engine...';
    });

    try {
      // Initialize SoLoud with proper parameters for the platform
      await SoLoud.instance.init();

      log('SoLoud initialized successfully');

      // Now proceed with WebSocket connection
      _initConnection();
    } catch (e) {
      log('Error initializing SoLoud: $e');
      setState(() {
        connectionStatus = 'Audio Engine Failed: $e';
        isConnecting = false;
      });
    }
  }

  @override
  void dispose() {
    // Dispose animation controllers (Keep existing)
    _logoAnimationController.dispose();
    _buttonScaleController.dispose();
    _buttonSlideController.dispose();
    _statusAnimationController.dispose();
    _micIconController.dispose();
    _speakingAnimationController.dispose();
    _progressAnimationController.dispose();

    // Cancel timers
    silenceTimer?.cancel();
    sendTimer?.cancel();
    _speakingTimeoutTimer?.cancel();
    _audioEventSubscription?.cancel(); // Cancel SoLoud event listener

    // Stop recording if active
    if (isRecording)
      stopStream();
    else {
      try {
        // Only close the channel if it exists
        channel.sink.close();
      } catch (e) {
        log("Error closing WebSocket channel: $e");
      }
    }
    record.dispose();

    // Clean up SoLoud resources
    if (currentSound != null) {
      try {
        SoLoud.instance.disposeSource(currentSound!);
      } catch (e) {
        log('Error disposing sound source: $e');
      }
    }

    // Make sure any active sound is stopped
    if (_currentSoundHandle != null) {
      try {
        SoLoud.instance.stop(_currentSoundHandle!);
      } catch (e) {
        log('Error stopping sound: $e');
      }
    }

    log('HomePage disposed');
    super.dispose();
  }

  // --- UI Widgets (Keep existing: _recordingButton, _buildLogo, _buildStatusMessage, build method) ---
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
                ? Icons
                    .hearing // Using 'hearing' icon for AI speaking
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
                : 'Press microphone to initialize audio and start speaking');

    final textColor =
        isAiSpeaking
            ? NativeFlowTheme.accentPurple
            : isRecording
            ? NativeFlowTheme.primaryBlue
            : NativeFlowTheme.textDark;

    // Trigger animation reset when message changes
    if (message != serverResponse ||
        isConnecting ||
        isAiSpeaking ||
        isRecording) {
      if (_statusAnimationController.status == AnimationStatus.completed) {
        _statusAnimationController.reset();
        _statusAnimationController.forward();
      }
    }

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
              // Show progress indicator when connecting (after SoLoud init)
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
                    opacity: const AlwaysStoppedAnimation(1.0), // Simpler fade
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
    if (!SoLoud.instance.isInitialized) {
      log("Error: Attempted to connect before SoLoud was initialized.");
      setState(() {
        isConnecting = false; // Stop showing indefinite progress
        connectionStatus = "Audio Engine Error.";
      });
      return;
    }

    setState(() {
      isConnecting = true;
      connectionStatus = 'Connecting to server...';
    });

    try {
      // No need for audio session or platform-specific setup here, SoLoud handles it.

      final wsUrl = _getWebSocketUrl();
      log('Connecting to WebSocket URL: $wsUrl');
      channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Listen for WebSocket messages
      _listenForAudioStream();

      // Start listening to SoLoud player events AFTER initializing connection
      _listenToSoLoudEvents();

      setState(() {
        isConnecting = false;
        connectionStatus = 'Connected';
        // Ensure serverResponse is also cleared or set appropriately
        serverResponse = '';
      });

      log('WebSocket connected successfully');
    } catch (e) {
      log('Error initializing connection: $e');
      if (mounted) {
        setState(() {
          isConnecting = false;
          connectionStatus = 'Connection failed: $e';
        });
      }
    }
  }

  // Keep _getWebSocketUrl as is
  String _getWebSocketUrl() {
    if (kIsWeb) {
      // Use localhost for web development, adjust for production
      return 'ws://localhost:9083';
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      // Special IP for Android emulator
      return 'ws://10.0.2.2:9083';
    } else {
      // Default for iOS simulator and other platforms (macOS, Windows, Linux)
      return 'ws://localhost:9083';
    }
  }

  // Remove _initWebAudio, _initAudioSession

  // --- Recording Logic (Keep existing methods: _startSilenceDetection, _showPermissionAlert, _openAppSettings, sendJsonAudioStream, sendBufferedAudio, stopStream, stopRecordingOnly) ---
  void _startSilenceDetection() {
    silenceTimer?.cancel();
    silentSeconds = 0;

    silenceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      silentSeconds++;

      if (silentSeconds >= 5) {
        log('5 seconds of silence detected - stopping recording');
        stopRecordingOnly(); // Stop recording but keep socket open
        if (mounted) setState(() => isRecording = false);
        silenceTimer?.cancel();
      }
    });
  }

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

  // Placeholder - use permission_handler or app_settings package for real implementation
  void _openAppSettings() async {
    log(
      'Opening app settings (requires permission_handler or app_settings package)',
    );
    // Example using permission_handler (add dependency first):
    // import 'package:permission_handler/permission_handler.dart';
    // await openAppSettings();
  }

  void sendJsonAudioStream() async {
    if (isConnecting || isAiSpeaking) {
      log('Cannot record while connecting or AI speaking');
      return;
    }

    // First, ensure SoLoud is initialized
    if (!SoLoud.instance.isInitialized) {
      await _initSoLoud();
      // If initialization failed, don't proceed
      if (!SoLoud.instance.isInitialized) {
        return;
      }
    }

    // --- Permission Check ---
    bool hasPermission = await record.hasPermission();
    if (!hasPermission) {
      log('Microphone permission not granted');
      if (mounted) _showPermissionAlert(context); // Show an alert
      return; // Don't proceed if permission is denied
    }
    // --- End Permission Check ---

    if (!isRecording) {
      // Clear previous server response and audio buffer
      setState(() {
        serverResponse = '';
      });
      _pcmBuffer.clear(); // Clear playback buffer for new interaction
      await SoLoud.instance.disposeAllSources(); // Stop any residual playback

      channel.sink.add(
        jsonEncode({
          "setup": {"generation_config": {}},
        }),
      );
      log('Config sent');

      try {
        final stream = await record.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits, // Keep recording format
            sampleRate: 16000, // Keep recording format
            numChannels: 1, // Keep recording format
          ),
        );

        audioBuffer.clear(); // Clear recording buffer
        sendTimer?.cancel();
        _startSilenceDetection(); // Start silence detection

        // Send data periodically
        sendTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
          // Send more frequently
          if (audioBuffer.isNotEmpty) {
            sendBufferedAudio();
            silentSeconds = 0; // Reset silence timer on send
          }
        });

        stream.listen(
          (List<int> chunk) {
            if (chunk.isNotEmpty) {
              audioBuffer.addAll(chunk);
              // log('Buffered ${chunk.length} bytes, Total: ${audioBuffer.length}'); // Can be verbose
              silentSeconds = 0; // Reset silence detection on receiving audio
            }
          },
          onError: (error) {
            log('Recording Stream error: $error');
            if (mounted) setState(() => isRecording = false);
            sendTimer?.cancel();
            silenceTimer?.cancel();
          },
          onDone: () {
            log('Recording Stream done');
            sendTimer?.cancel();
            silenceTimer?.cancel();
            if (audioBuffer.isNotEmpty)
              sendBufferedAudio(); // Send any remaining audio
            if (mounted) setState(() => isRecording = false);
          },
        );
        if (mounted) setState(() => isRecording = true);
      } catch (e) {
        log('Error starting recording stream: $e');
        if (mounted) {
          setState(() => serverResponse = "Error starting recording.");
        }
      }
    } else {
      log('Stop recording pressed');
      stopRecordingOnly(); // Stop recording
      if (mounted) setState(() => isRecording = false);
    }
  }

  void sendBufferedAudio() {
    if (audioBuffer.isNotEmpty && channel.closeCode == null) {
      // Check if channel is open
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
      // log('Sent ${audioBuffer.length} bytes'); // Can be verbose
      audioBuffer.clear();
    } else if (channel.closeCode != null) {
      log('WebSocket closed, cannot send audio.');
      // Stop recording if socket is closed
      if (isRecording) {
        stopRecordingOnly();
        if (mounted) setState(() => isRecording = false);
      }
    }
  }

  // Keep stopStream (closes socket too)
  void stopStream() async {
    silenceTimer?.cancel();
    sendTimer?.cancel();
    await record.stop();
    if (audioBuffer.isNotEmpty)
      sendBufferedAudio(); // Send final chunk if needed
    channel.sink.close(); // Close WebSocket
    log('Stream & WebSocket closed');
    if (mounted) setState(() => isRecording = false);
  }

  // Keep stopRecordingOnly (stops recording, leaves socket open)
  void stopRecordingOnly() async {
    silenceTimer?.cancel();
    sendTimer?.cancel();
    await record.stop();
    if (audioBuffer.isNotEmpty) sendBufferedAudio(); // Send final chunk
    log('Recording stopped');
    // Don't set isRecording = false here, handled by the calling method or onDone callback
  }

  // --- Playback Logic (Using flutter_soloud) ---

  void _listenToSoLoudEvents() {
    _audioEventSubscription?.cancel();

    // Create a simple timer to periodically check playback status
    _audioEventSubscription = Stream.periodic(
      const Duration(milliseconds: 500),
    ).listen((_) {
      // Only check if we have an active sound handle and we're in speaking state
      if (_currentSoundHandle != null && isAiSpeaking) {
        try {
          // Only perform position check on non-web platforms
          if (!kIsWeb) {
            // Check playback position - exception will be thrown if sound is no longer playing
            final position = SoLoud.instance.getPosition(_currentSoundHandle!);
            log('Sound position: ${position.inMilliseconds}ms');

            // If position is near the end (for very short sounds), consider it finished
            if (position.inMilliseconds > 20000) {
              if (mounted) {
                setState(() {
                  isAiSpeaking = false;
                  _currentSoundHandle = null;
                });
              }
              log('Sound playback completed (reached end)');
            }
          }
        } catch (e) {
          // Exception means sound is no longer playing (handle invalid)
          if (mounted && isAiSpeaking) {
            setState(() {
              isAiSpeaking = false;
              _currentSoundHandle = null;
            });
          }
          log('Sound playback completed (handle invalid)');
        }
      }
    });
    log('Started periodic check for sound completion');
  }

  void _listenForAudioStream() {
    channel.stream.listen(
      (message) {
        try {
          var data = jsonDecode(message as String);

          // Handle text messages
          if (data['text'] != null) {
            if (mounted) {
              setState(() => serverResponse = "${data['text']}");
            }
            log('Received text: ${data['text']}');
          }
          // Handle audio_start signal
          else if (data['audio_start'] == true) {
            log('Received audio_start signal');
            if (mounted) {
              setState(() {
                isAiSpeaking = true; // Set speaking true *immediately*
                _pcmBuffer.clear(); // Clear buffer for new response
              });
            }
            _lastAudioChunkTime = DateTime.now();
            // Reset speaking timeout timer
            _speakingTimeoutTimer?.cancel();
            _startSpeakingTimeoutCheck(); // Start timeout check
          }
          // Handle audio chunks - buffer them
          else if (data['audio'] != null) {
            String base64Audio = data['audio'] as String;
            var pcmBytes = base64Decode(base64Audio);
            _pcmBuffer.addAll(pcmBytes);
            _lastAudioChunkTime = DateTime.now(); // Update time
            // log('Buffered audio chunk: ${pcmBytes.length} bytes, Total buffered: ${_pcmBuffer.length}'); // Verbose

            // Reset speaking timeout timer as we received a chunk
            _speakingTimeoutTimer?.cancel();
            _startSpeakingTimeoutCheck();
          }
          // Handle turn_complete flag - play all buffered audio
          else if (data['turn_complete'] == true) {
            log('Turn complete signal received');
            _speakingTimeoutTimer?.cancel(); // Cancel timeout check

            if (_pcmBuffer.isNotEmpty) {
              log(
                'Turn complete: Playing buffered audio (${_pcmBuffer.length} bytes)',
              );
              _playAudioWithSoloud(List<int>.from(_pcmBuffer)); // Play a copy
              _pcmBuffer.clear(); // Clear buffer after copying
              // isAiSpeaking will be set to false by the SoLoud event listener
            } else {
              log('Turn complete received, but no audio was buffered.');
              // No audio to play, so AI is done speaking
              if (mounted && isAiSpeaking) {
                // Only update if currently speaking
                setState(() => isAiSpeaking = false);
              }
            }
          }
        } catch (e, s) {
          log(
            'WebSocket message processing error: $e\n$s',
            error: e,
            stackTrace: s,
          );
        }
      },
      onError: (error) {
        log('WebSocket error: $error');
        if (mounted) {
          setState(() {
            connectionStatus = 'Connection error';
            isAiSpeaking = false;
            isRecording = false;
            isConnecting = true; // Indicate disconnected state
          });
        }
        // Consider adding reconnection logic here or a manual reconnect button
      },
      onDone: () {
        log('WebSocket closed');
        if (mounted) {
          setState(() {
            connectionStatus = 'Connection closed';
            isAiSpeaking = false;
            isRecording = false;
            isConnecting = true; // Indicate disconnected state
          });
        }
        _speakingTimeoutTimer?.cancel(); // Cancel timeout on disconnect
        try {
          // Use stop method for all sounds instead of stopAll
          if (_currentSoundHandle != null) {
            SoLoud.instance.stop(_currentSoundHandle!);
          }
        } catch (e) {
          log('Error stopping sounds: $e');
        }
        if (mounted && isAiSpeaking) setState(() => isAiSpeaking = false);
      },
    );
  }

  // Start the timer to check for speaking timeout
  void _startSpeakingTimeoutCheck() {
    _speakingTimeoutTimer = Timer(const Duration(milliseconds: 1500), () {
      if (isAiSpeaking &&
          _lastAudioChunkTime != null &&
          DateTime.now().difference(_lastAudioChunkTime!).inMilliseconds >
              1400) {
        log(
          'No audio chunks received for 1.5 seconds, assuming AI is done speaking (Timeout)',
        );

        // If we have buffered audio, play it now
        if (_pcmBuffer.isNotEmpty) {
          log(
            'Playing buffered audio after timeout (${_pcmBuffer.length} bytes)',
          );
          _playAudioWithSoloud(List<int>.from(_pcmBuffer));
          _pcmBuffer.clear();
        } else {
          // No audio buffered, just stop the speaking indicator
          if (mounted && isAiSpeaking) {
            setState(() {
              isAiSpeaking = false;
            });
          }
        }
      }
    });
  }

  // Play buffered PCM audio using SoLoud by adding a WAV header
  Future<void> _playAudioWithSoloud(List<int> pcmData) async {
    if (!SoLoud.instance.isInitialized) {
      log('Error: SoLoud not initialized, cannot play audio.');
      if (mounted) setState(() => isAiSpeaking = false);
      return;
    }

    if (pcmData.isEmpty) {
      log('Warning: Attempted to play empty audio buffer.');
      if (mounted) setState(() => isAiSpeaking = false);
      return;
    }

    if (mounted && !isAiSpeaking) {
      setState(() {
        isAiSpeaking = true;
      });
    }

    try {
      // Stop previous sound/dispose source (remains the same)
      if (_currentSoundHandle != null) {
        try {
          await SoLoud.instance.stop(_currentSoundHandle!);
          _currentSoundHandle = null;
        } catch (e) {
          log('Error stopping previous sound: $e');
        }
      }
      if (currentSound != null) {
        try {
          await SoLoud.instance.disposeSource(currentSound!);
          currentSound = null;
        } catch (e) {
          log('Error disposing previous source: $e');
        }
      }

      // --- Create WAV data properly ---
      const int sampleRate = 24000;
      const int numChannels = 1;
      const int bitsPerSample = 16;

      final headerBytes = _generateWavHeader(
        pcmData.length,
        sampleRate,
        numChannels,
        bitsPerSample,
      );

      // Use Uint8List for combined data
      final Uint8List combinedWavData = Uint8List(
        headerBytes.length + pcmData.length,
      );
      combinedWavData.setRange(0, headerBytes.length, headerBytes);
      combinedWavData.setRange(
        headerBytes.length,
        combinedWavData.length,
        pcmData,
      );

      // Use loadMem for ALL platforms
      try {
        log(
          'Loading WAV data into SoLoud (${combinedWavData.length} bytes) for ${kIsWeb ? "Web" : "Native"}...',
        );
        // Use loadMem for all platforms
        currentSound = await SoLoud.instance.loadMem(
          // Use a unique identifier or just a generic name if needed
          'memory_audio_${DateTime.now().millisecondsSinceEpoch}.wav',
          combinedWavData,
        );

        if (currentSound == null) {
          log('Error: Failed to load audio data from memory.');
          if (mounted) setState(() => isAiSpeaking = false);
          return;
        }

        // Play the sound
        _currentSoundHandle = await SoLoud.instance.play(currentSound!);
        log('Playing sound with handle: $_currentSoundHandle');
      } catch (e, s) {
        // Log error for both web and native if loadMem fails
        log('Error playing audio from memory: $e\n$s', error: e, stackTrace: s);
        if (mounted) setState(() => isAiSpeaking = false);
        // You could potentially add the file fallback here *only* for non-web if needed
        // if (!kIsWeb) { /* ... file fallback code ... */ }
      }
    } catch (e, s) {
      log(
        'General error in _playAudioWithSoloud: $e\n$s',
        error: e,
        stackTrace: s,
      );
      if (mounted) {
        setState(() {
          isAiSpeaking = false;
          _currentSoundHandle = null;
        });
      }
    }
  }

  // Utility to generate a simple WAV header for raw PCM data
  List<int> _generateWavHeader(
    int pcmDataLength,
    int sampleRate,
    int numChannels,
    int bitsPerSample,
  ) {
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = pcmDataLength;
    final chunkSize =
        36 + dataSize; // 36 bytes for header fields excluding RIFF id and size

    final header = ByteData(44); // Standard WAV header size

    // RIFF chunk descriptor
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, chunkSize, Endian.little);
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'

    // fmt sub-chunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // Subchunk1Size for PCM
    header.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);

    // data sub-chunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, dataSize, Endian.little);

    return header.buffer.asUint8List();
  }
} // End _HomePageState
