import 'dart:async';
import 'dart:convert'; // For JSON decoding/encoding
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // Check if running on web
import 'package:logger/logger.dart'; // For logging
import 'dart:js_interop'; // Import new JS interop package
import 'package:flutter_animate/flutter_animate.dart'; // For UI animations
import 'package:web/web.dart' as web; // Replace dart:html with web package
import 'dart:ui_web' as ui_web; // For platform view registry

// Define JS bindings using extension types
// These correspond to functions and structures in web/gemini_bridge.js

// Define a type for the callbacks object passed to initializeBridge in JS
extension type BridgeCallbacks._(JSObject _) implements JSObject {
  external BridgeCallbacks({
    JSFunction? onWebSocketOpen,
    JSFunction? onWebSocketMessage,
    JSFunction? onWebSocketClose,
    JSFunction? onWebSocketError,
    JSFunction? onRecordingStateChange,
  });

  external JSFunction? get onWebSocketOpen;
  external JSFunction? get onWebSocketMessage;
  external JSFunction? get onWebSocketClose;
  external JSFunction? get onWebSocketError;
  external JSFunction? get onRecordingStateChange;
}

// Declare JS functions from gemini_bridge.js that we want to call from Dart
@JS('initializeBridge')
external bool initializeBridge(BridgeCallbacks callbacks);

@JS('connectWebSocket')
external void connectWebSocket();

@JS('sendWebSocketMessage')
external bool sendWebSocketMessage(String message);

@JS('startMediaStream')
external JSObject startMediaStream(bool useCamera);

@JS('stopMediaStream')
external void stopMediaStream();

@JS('startAudioInput')
external JSObject startAudioInput();

@JS('stopAudioInput')
external void stopAudioInput();

@JS('initializeAudioOutput')
external JSObject initializeAudioOutput();

@JS('playAudioChunk')
external void playAudioChunk(String base64AudioChunk);

@JS('isWebSocketConnected')
external bool isWebSocketConnected();

// --- Flutter Application Code ---

void main() {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logger
  final logger = Logger(
    printer: PrettyPrinter(
      methodCount: 1,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  if (kIsWeb) {
    // Create video container and video element
    final videoContainer = web.document.createElement('div')
      ..id = 'video-container';
    videoContainer.setAttribute('style', '''
      width: 100%;
      height: 100%;
      background-color: black;
      position: relative;
    ''');

    final videoElement = web.document.createElement('video')
      ..id = 'videoElement'
      ..setAttribute('autoplay', '')
      ..setAttribute('muted', '');
    videoElement.setAttribute('style', '''
      width: 100%;
      height: 100%;
      object-fit: contain;
      background-color: black;
    ''');

    final canvasElement = web.document.createElement('canvas')
      ..id = 'canvasElement';
    canvasElement.setAttribute('style', 'display: none;');

    videoContainer.appendChild(videoElement);
    videoContainer.appendChild(canvasElement);
    web.document.body?.appendChild(videoContainer);

    // Register the view factory for HtmlElementView
    ui_web.platformViewRegistry.registerViewFactory(
      'videoElement',
      (int viewId) {
        logger.i("ViewFactory called with viewId: $viewId");
        return videoElement;
      },
    );
    logger.i("HtmlElementView factory registered for 'videoElement'");
  }

  // Initialize animations package
  Animate.restartOnHotReload = true;

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemini Live Flutter',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple, // Example color scheme
        brightness: Brightness.light,
        // Customize FloatingActionButton theme slightly
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: Colors.deepPurple[600],
          foregroundColor: Colors.white,
        ),
      ),
      home: const GeminiLiveScreen()
          .animate()
          .fadeIn(duration: 600.ms, curve: Curves.easeOutQuad),
      debugShowCheckedModeBanner: false, // Hide debug banner
    );
  }
}

// --- Main Screen Widget ---

class GeminiLiveScreen extends StatefulWidget {
  const GeminiLiveScreen({super.key});

  @override
  State<GeminiLiveScreen> createState() => _GeminiLiveScreenState();
}

class _GeminiLiveScreenState extends State<GeminiLiveScreen> {
  final Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 1,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );
  final List<ChatMessage> _chatMessages = [];
  bool _isRecording = false;
  bool _webSocketConnected = false;
  bool _isConnecting = false; // Track initial connection attempt
  bool _isBridgeInitialized = false;
  final TextEditingController _textController = TextEditingController();
  Timer? _connectionCheckTimer;
  String _currentError = ''; // Store the last error message

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      logger.i('Flutter Web: Initializing Gemini Live Screen...');
      // Hide Flutter's loading spinner after a delay if it's still showing
      Future.delayed(const Duration(seconds: 3), () {
        try {
          // Force hide loading screen
          final loadingElement = web.document.getElementById('loading');
          if (loadingElement != null) {
            loadingElement.setAttribute('style', 'display: none;');
            logger.i('Force hidden loading screen');
          }
        } catch (e) {
          logger.e('Error hiding loading screen: $e');
        }
      });

      // We need to add a slightly longer delay to ensure DOM is fully ready
      Future.delayed(const Duration(milliseconds: 1000), _initializeAndConnect);

      // Add a timeout to hide loading spinner if initialization takes too long
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted && _isConnecting && !_webSocketConnected) {
          setState(() {
            _isConnecting = false;
            _currentError =
                'Initialization timed out. Check console for errors.';
          });
          _addSystemMessage(
              "Timed out waiting for initialization. Make sure the WebSocket server is running (python server.py).");
        }
      });
    } else {
      logger.w('This application is designed for Flutter Web.');
      // Handle non-web platform if necessary
    }
  }

  // Initialize JS bridge, connect WebSocket, start media
  Future<void> _initializeAndConnect() async {
    if (!kIsWeb) return;
    if (_isBridgeInitialized) {
      logger.i("Initialization already attempted.");
      return;
    }

    logger.i("Attempting to initialize JS Bridge and connect...");
    setState(() {
      _isConnecting = true; // Show connecting state
      _currentError = ''; // Clear previous errors
    });

    try {
      // Create the callbacks object, wrapping Dart functions with toJS
      final callbacks = BridgeCallbacks(
        onWebSocketOpen: _handleWebSocketOpen.toJS,
        onWebSocketMessage: _handleWebSocketMessage.toJS,
        onWebSocketClose: _handleWebSocketClose.toJS,
        onWebSocketError: _handleWebSocketError.toJS,
        onRecordingStateChange: _handleRecordingStateChange.toJS,
      );

      // Call the JS initializeBridge function
      _isBridgeInitialized = initializeBridge(callbacks);

      if (_isBridgeInitialized) {
        logger.i("JS Bridge Initialized Successfully.");

        // Create a global error handler for the UI
        try {
          web.window.addEventListener(
              'error',
              ((web.Event event) {
                logger.e("Global JS error: ${event.toString()}");
                if (event.toString().contains('Permission denied')) {
                  _setErrorState(
                      "Permission denied for camera or microphone access");
                }
              }).toJS as Never);
        } catch (e) {
          logger.e("Error setting up error handler: $e");
        }

        try {
          // Initialize audio output system (async JS call)
          await Future.value(initializeAudioOutput());
          logger.i("Audio Output Initialized successfully.");
        } catch (e) {
          logger.e("Error initializing audio output: $e");
          // Continue anyway, audio output failure shouldn't block the app
        }

        try {
          // Before trying to get media access, check if user prefers camera instead of screen
          bool useCameraPreferred = false; // Default to screen share

          // Try showing a dialog to ask the user which they prefer
          try {
            // First we'll use screen share, but we'll offer a button to switch to camera
            await Future.value(
                startMediaStream(useCameraPreferred)); // false for screen share
            logger.i("Media Stream Started successfully.");
          } catch (e) {
            logger.e("Error starting media stream: $e");
            // Instead of failing, add a manual option to try again with camera
            _addSystemMessage(
                "Media access failed. Click the camera icon in the appbar to try again.");
            setState(() {
              _currentError =
                  "Could not access media. Try camera or screen share from the app bar.";
            });
            // We'll continue with WebSocket connection anyway
          }
        } catch (e) {
          logger.e("Error during media initialization: $e");
          // Continue with WebSocket connection anyway
        }

        try {
          // Connect WebSocket (sync JS call, but events are async)
          connectWebSocket();
          logger.i("WebSocket connection initiated.");
        } catch (e) {
          logger.e("Error connecting WebSocket: $e");
          _setErrorState("Connection Error: ${e.toString()}");
          // This is critical, but we'll let the error handling code handle it
        }

        // Start timer to periodically check connection status via JS as a fallback
        _connectionCheckTimer?.cancel(); // Cancel previous timer if any
        _connectionCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (!mounted) return; // Check if widget is still in the tree
          final bool currentlyConnected = isWebSocketConnected();
          if (currentlyConnected != _webSocketConnected) {
            logger.d("Connection status changed (polled): $currentlyConnected");
            setState(() {
              _webSocketConnected = currentlyConnected;
              // If disconnected via polling, ensure recording state is false
              if (!currentlyConnected) _isRecording = false;
            });
          }
        });
      } else {
        logger.e("JS Bridge Initialization Failed! Check browser console.");
        _setErrorState("Failed to initialize core components.");
      }
    } catch (e) {
      logger.e("Error during initialization: $e");
      _setErrorState("Initialization Error: ${e.toString()}");
    } finally {
      // Update connecting state only if not already connected/failed
      if (mounted &&
          _isConnecting &&
          !_webSocketConnected &&
          _currentError.isEmpty) {
        // If still connecting after init attempts but no success/error yet, wait for callbacks
        // Timeout added in initState will eventually update the UI if needed
      } else if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  // Set error state and update UI
  void _setErrorState(String errorMessage) {
    logger.e("Error State Set: $errorMessage");
    if (!mounted) return;
    setState(() {
      _currentError = errorMessage;
      _webSocketConnected = false;
      _isConnecting = false;
      _isRecording = false;
    });
    _addSystemMessage("Error: $errorMessage");
  }

  // --- Callback Handlers (Called from JS via allowInterop) ---

  void _handleWebSocketOpen() {
    logger.i("WebSocket Opened (via JS callback)");
    if (!mounted) return;
    setState(() {
      _webSocketConnected = true;
      _isConnecting = false; // Successfully connected
      _currentError = ''; // Clear any previous errors
    });
    _addSystemMessage("Connected to Gemini.");
  }

  void _handleWebSocketMessage(String message) {
    // logger.d("WebSocket Message Received (raw): $message"); // Log raw message if needed
    if (!mounted) return;
    try {
      final data = jsonDecode(message);
      final response = GeminiResponse.fromJson(data);

      if (response.text != null && response.text!.isNotEmpty) {
        logger.i("Received Text: ${response.text}");
        _addGeminiMessage(response.text!);
      }
      if (response.audio != null && response.audio!.isNotEmpty) {
        logger.i("Received Audio Chunk for playback.");
        // Play the audio chunk using the JS bridge function
        playAudioChunk(response.audio!);
      }
      // Handle turn_complete if needed (e.g., re-enable mic button after Gemini speaks)
      if (response.turnComplete ?? false) {
        logger.i("Turn Complete message received.");
        // Example: Re-enable mic automatically after Gemini finishes
        // if (_isRecording) { // Or based on some other logic
        //   _stopRecording();
        // }
      }
    } catch (e, stacktrace) {
      logger.e("Error processing WebSocket message: $e\n$stacktrace");
      _addSystemMessage("Error processing server message.");
    }
  }

  void _handleWebSocketClose(int code, String reason) {
    logger
        .w("WebSocket Closed (via JS callback): Code=$code, Reason='$reason'");
    if (!mounted) return;
    final message = "Connection closed: $reason (Code: $code)";
    setState(() {
      _webSocketConnected = false;
      _isConnecting = false;
      _isRecording = false; // Stop recording state if connection drops
      if (_currentError.isEmpty) {
        // Don't overwrite specific errors
        _currentError = message;
      }
    });
    _addSystemMessage(message);
  }

  void _handleWebSocketError(String error) {
    logger.e("WebSocket Error (via JS callback): $error");
    if (!mounted) return;
    _setErrorState("Connection error: $error");
  }

  void _handleRecordingStateChange(bool isNowRecording) {
    logger.i("Recording State Changed (via JS callback): $isNowRecording");
    if (!mounted) return;
    // Only update state if it's different to avoid unnecessary rebuilds
    if (_isRecording != isNowRecording) {
      setState(() {
        _isRecording = isNowRecording;
      });
    }
  }

  // --- UI Interaction Methods ---

  void _startRecording() {
    if (!kIsWeb || !_isBridgeInitialized) {
      logger.w("Cannot start recording: Not on web or bridge not initialized.");
      return;
    }
    if (_isRecording) {
      logger.w("Already recording.");
      return;
    }
    if (!_webSocketConnected) {
      logger.w("Cannot start recording: WebSocket not connected.");
      _addSystemMessage("Connect to server before recording.");
      return;
    }
    logger.i("UI: Requesting Start Recording via JS...");
    // Convert JSObject to Future and handle potential errors
    Future.value(startAudioInput()).catchError((e) {
      logger.e("Error starting audio input from Dart: $e");
      _setErrorState("Microphone Error: ${e.toString()}");
      return JSObject(); // Return an empty JSObject to satisfy the type requirement
    });
    // State update (_isRecording = true) will happen via the _handleRecordingStateChange callback
  }

  void _stopRecording() {
    if (!kIsWeb || !_isBridgeInitialized) {
      logger.w("Cannot stop recording: Not on web or bridge not initialized.");
      return;
    }
    if (!_isRecording) {
      logger.w("Not recording.");
      return;
    }
    logger.i("UI: Requesting Stop Recording via JS...");
    stopAudioInput(); // Call the sync JS function
    // State update (_isRecording = false) will happen via the _handleRecordingStateChange callback
  }

  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (!kIsWeb || !_isBridgeInitialized) {
      logger.w("Cannot send text: Not on web or bridge not initialized.");
      return;
    }
    if (text.isEmpty) {
      logger.w("Cannot send empty text message.");
      return;
    }
    if (!_webSocketConnected) {
      logger.w("Cannot send text: WebSocket not connected.");
      _addSystemMessage("Connect to server before sending messages.");
      return;
    }

    logger.i("UI: Sending Text Message: $text");
    _addUserMessage(text); // Add to local chat UI immediately

    // Construct the payload expected by the Gemini API via the server
    // This structure should match what `sendAudioChunk` sends, but only with text.
    // Adjust if your server expects a different format for text-only input.
    final payload = {
      "realtime_input": {
        "media_chunks": [
          {"mime_type": "text/plain", "data": text} // Example structure
          // If your server expects just text:
          // "text": text
        ]
      }
    };

    try {
      final success = sendWebSocketMessage(jsonEncode(payload));
      if (success) {
        _textController.clear(); // Clear input field on successful send attempt
      } else {
        logger.e("Failed to send text message via WebSocket.");
        _addSystemMessage("Error: Could not send message.");
      }
    } catch (e) {
      logger.e("Error encoding/sending text message: $e");
      _addSystemMessage("Error sending message.");
    }
  }

  // --- Chat Message Helpers ---

  void _addChatMessage(String text, bool isUser, {bool isSystem = false}) {
    if (!mounted) return;
    // Optional: Limit chat history size
    // if (_chatMessages.length > 100) {
    //   _chatMessages.removeAt(0);
    // }
    setState(() {
      _chatMessages
          .add(ChatMessage(text: text, isUser: isUser, isSystem: isSystem));
    });
    // Consider scrolling to the bottom here using a ScrollController
  }

  void _addUserMessage(String text) => _addChatMessage(text, true);
  void _addGeminiMessage(String text) => _addChatMessage(text, false);
  void _addSystemMessage(String text) =>
      _addChatMessage(text, false, isSystem: true);

  @override
  void dispose() {
    logger.i("Disposing GeminiLiveScreen");
    _connectionCheckTimer?.cancel();
    if (kIsWeb && _isBridgeInitialized) {
      // Clean up JS resources when the widget is removed
      stopMediaStream(); // Stop video stream and capture
      stopAudioInput(); // Stop audio capture if running
      // Optionally close WebSocket if desired on dispose, though the bridge handles closures too
      // webSocket?.close();
    }
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determine video aspect ratio (default or could be dynamic later)
    const double videoAspectRatio = 640 / 480;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Live Flutter')
            .animate()
            .fadeIn(duration: 500.ms)
            .shimmer(
                duration: 1200.ms,
                delay: 300.ms,
                color: Colors.white.withValues(alpha: 204)),
        backgroundColor: Colors.deepPurple, // Match theme
        elevation: 4.0,
        actions: [
          // Media Access Controls
          IconButton(
            icon: Icon(Icons.screen_share),
            tooltip: 'Try Screen Share',
            onPressed: () async {
              try {
                await Future.value(startMediaStream(false));
                setState(() {
                  _currentError = ''; // Clear error if successful
                });
              } catch (e) {
                _setErrorState("Screen share error: ${e.toString()}");
              }
            },
          ),
          IconButton(
            icon: Icon(Icons.camera_alt),
            tooltip: 'Try Camera',
            onPressed: () async {
              try {
                await Future.value(startMediaStream(true));
                setState(() {
                  _currentError = ''; // Clear error if successful
                });
              } catch (e) {
                _setErrorState("Camera error: ${e.toString()}");
              }
            },
          ),
          // Connection Status Chip
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
              child: Chip(
                avatar: Icon(
                  _webSocketConnected
                      ? Icons.check_circle
                      : (_isConnecting ? Icons.hourglass_empty : Icons.error),
                  color: _webSocketConnected
                      ? Colors.green[700]
                      : (_isConnecting ? Colors.orange[700] : Colors.red[700]),
                  size: 18,
                ),
                label: Text(
                  _webSocketConnected
                      ? 'Connected'
                      : (_isConnecting ? 'Connecting...' : 'Disconnected'),
                  style: TextStyle(color: Colors.grey[800]),
                ),
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              )
                  .animate(target: _webSocketConnected ? 1.0 : 0.8)
                  .scaleXY(duration: 300.ms),
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh),
            tooltip: 'Restart connection',
            onPressed: () {
              _initializeAndConnect();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Video feed area
          Container(
            color: Colors.black, // Background for the video area
            child: AspectRatio(
              aspectRatio: videoAspectRatio,
              // Use HtmlElementView to display the <video> element managed by JS
              child: _isBridgeInitialized
                  ? Stack(
                      children: [
                        HtmlElementView(viewType: 'videoElement'),
                        if (_isConnecting)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  color: Colors.white,
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'Initializing video...',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: Colors.white,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Initializing video...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
            ),
          ).animate().fadeIn(duration: 500.ms),

          // Error Display Area
          if (_currentError.isNotEmpty)
            Container(
              color: Colors.red[100],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(_currentError,
                          style: TextStyle(color: Colors.red[900]))),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: Colors.red[700]),
                    onPressed: () => setState(() => _currentError = ''),
                  )
                ],
              ),
            ).animate().shake(hz: 2, duration: 500.ms),

          // Chat messages area
          Expanded(
            child: Container(
              color: Colors.grey[100], // Background for chat list
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: ListView.builder(
                // Consider adding a ScrollController to scroll to bottom
                itemCount: _chatMessages.length,
                itemBuilder: (context, index) {
                  final message = _chatMessages[index];
                  // Use a key for better list performance if items change order/are removed
                  return ChatBubble(
                      key: ValueKey(message.hashCode + index),
                      message: message);
                },
              ),
            ),
          ),

          // Input Controls Area
          Container(
            padding: const EdgeInsets.all(12.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 13),
                  blurRadius: 8,
                  offset: const Offset(0, -2), // Shadow above the input area
                )
              ],
            ),
            child: Row(
              children: [
                // Text Input Field
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: _webSocketConnected
                            ? 'Type a message...'
                            : 'Connect to send messages',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) =>
                          _sendTextMessage(), // Send on keyboard submit
                      enabled: _webSocketConnected, // Disable if not connected
                      minLines: 1,
                      maxLines: 3, // Allow multi-line input
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Send Button
                IconButton(
                  icon: Icon(Icons.send,
                      color: Theme.of(context).colorScheme.primary),
                  onPressed: _webSocketConnected
                      ? _sendTextMessage
                      : null, // Disable if not connected
                  tooltip: 'Send Message',
                ),

                const SizedBox(width: 4),

                // Microphone Buttons (conditionally enabled)
                FloatingActionButton(
                  heroTag: 'startMicBtn', // Unique Hero Tag is important
                  mini: true, // Smaller button
                  onPressed:
                      (_isRecording || !_webSocketConnected || _isConnecting)
                          ? null
                          : _startRecording,
                  backgroundColor:
                      (_isRecording || !_webSocketConnected || _isConnecting)
                          ? Colors.grey[400]
                          : Theme.of(context).colorScheme.primary,
                  tooltip: _isRecording ? 'Recording...' : 'Start Recording',
                  child: Icon(Icons.mic, color: Colors.white),
                )
                    .animate(target: _isRecording ? 1 : 0)
                    .scaleXY(end: 0.9, duration: 200.ms),

                const SizedBox(width: 8),

                FloatingActionButton(
                  heroTag: 'stopMicBtn', // Unique Hero Tag
                  mini: true, // Smaller button
                  onPressed: (!_isRecording || !_webSocketConnected)
                      ? null
                      : _stopRecording,
                  backgroundColor:
                      _isRecording ? Colors.red[600] : Colors.grey[400],
                  tooltip: 'Stop Recording',
                  child: const Icon(Icons.mic_off, color: Colors.white),
                )
                    .animate(target: _isRecording ? 1 : 0)
                    .scaleXY(begin: 0.9, end: 1.0, duration: 200.ms)
                    .animate(
                      target: _isRecording ? 1 : 0,
                      onPlay: (controller) => _isRecording
                          ? controller.repeat()
                          : controller.stop(),
                    )
                    .then(delay: 200.ms) // Only pulse when recording
                    .tint(
                        color: Colors.red.withValues(alpha: 128),
                        duration: 800.ms,
                        curve: Curves.easeInOut)
                    .then(delay: 800.ms)
                    .tint(
                        color: Colors.transparent,
                        duration: 800.ms,
                        curve: Curves.easeInOut),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Helper Classes ---

// Chat message data class
class ChatMessage {
  final String text;
  final bool isUser;
  final bool isSystem; // Flag for system messages

  ChatMessage(
      {required this.text, required this.isUser, this.isSystem = false});
}

// Chat bubble widget for displaying messages
class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final isSystem = message.isSystem;

    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final color = isSystem
        ? Colors.grey[200] // System message background
        : (isUser
            ? theme.colorScheme.primary
            : Colors.grey[300]); // User vs Gemini background
    final textColor = isSystem
        ? Colors.grey[600] // System message text color
        : (isUser
            ? theme.colorScheme.onPrimary
            : Colors.black87); // User vs Gemini text color
    final margin = isUser
        ? const EdgeInsets.only(top: 4, bottom: 4, left: 60, right: 8)
        : const EdgeInsets.only(top: 4, bottom: 4, right: 60, left: 8);
    final borderRadius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
            topRight: Radius.circular(4), // Slightly different corner for user
          )
        : const BorderRadius.only(
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
            topLeft: Radius.circular(4), // Slightly different corner for others
          );

    return Align(
      alignment: alignment,
      child: Container(
        margin: margin,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            boxShadow: isSystem
                ? []
                : [
                    // No shadow for system messages
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 13),
                      blurRadius: 3,
                      offset: Offset(1, 1),
                    )
                  ]),
        child: Text(
          message.text,
          style: TextStyle(
              color: textColor,
              fontStyle: isSystem ? FontStyle.italic : FontStyle.normal),
        ),
      )
          .animate() // Add entry animation
          .scale(
              begin: const Offset(0.8, 0.8),
              duration: 250.ms,
              curve: Curves.easeOutBack)
          .fade(duration: 250.ms)
          .slide(
              begin: Offset(isUser ? 0.1 : -0.1, 0),
              duration: 250.ms,
              curve: Curves.easeOut),
    );
  }
}

// Helper class for parsing Gemini JSON responses (adjust based on actual server output)
class GeminiResponse {
  final String? text;
  final String? audio; // Base64 encoded audio
  final bool? turnComplete;

  GeminiResponse({this.text, this.audio, this.turnComplete});

  // Factory constructor to parse the JSON map
  factory GeminiResponse.fromJson(Map<String, dynamic> json) {
    // Handle potential nesting if server wraps content
    final serverContent = json['server_content'];
    final modelTurn = serverContent?['model_turn'];
    final parts = modelTurn?['parts'] as List<dynamic>?;

    String? extractedText;
    String? extractedAudio;

    if (parts != null) {
      for (var part in parts) {
        if (part is Map<String, dynamic>) {
          if (part.containsKey('text')) {
            extractedText =
                (extractedText ?? '') + part['text']; // Concatenate text parts
          } else if (part.containsKey('inline_data')) {
            final inlineData = part['inline_data'];
            if (inlineData is Map<String, dynamic> &&
                inlineData['mime_type']?.startsWith('audio/') == true) {
              // Assuming server sends base64 encoded data directly in 'data'
              // If not, adjust based on server.py's encoding (it uses b64encode)
              extractedAudio =
                  inlineData['data']; // This should already be base64
            }
          }
        }
      }
    }

    // Also check top-level fields if server sends them directly sometimes
    extractedText ??= json['text'] as String?;
    extractedAudio ??= json['audio'] as String?; // Base64 audio

    // Check for turn completion flag
    final bool? isTurnComplete = serverContent?['turn_complete'] as bool? ??
        json['turn_complete'] as bool?;

    return GeminiResponse(
      text: extractedText,
      audio: extractedAudio,
      turnComplete: isTurnComplete,
    );
  }
}
