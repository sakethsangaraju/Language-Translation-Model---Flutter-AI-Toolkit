// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// A simplified WebRTC-like helper that actually uses Socket.IO for communication
/// This avoids the complexities of true WebRTC while providing a similar API
class WebRTCHelper {
  // Singleton instance
  static final WebRTCHelper _instance = WebRTCHelper._internal();
  factory WebRTCHelper() => _instance;
  WebRTCHelper._internal();

  // Logger
  final Logger logger = Logger();

  // Socket for signaling and audio
  io.Socket? _socket;

  // Media stream
  MediaStream? _localStream;
  html.MediaStream? _webStream;
  html.MediaRecorder? _webRecorder;
  List<html.Blob> _audioChunks = [];

  // Raw audio data for direct playback
  Uint8List? rawAudioData;

  // Callbacks
  Function(String)? onTranscription;
  Function(String)? onTranslation;
  Function(String)? onError;
  Function(String)? onAudioReceived;
  Function(Uint8List)? onRawAudioCaptured; // New callback for raw audio

  // State
  bool _isInitialized = false;
  bool _isConnected = false;
  bool _isRecording = false;

  // Initialize
  Future<void> initialize(io.Socket socket) async {
    _socket = socket;

    // Set up event listeners
    _setupEventListeners();

    _isInitialized = true;
    logger.i('WebRTC-like helper initialized');
  }

  // Set up Socket.IO event listeners
  void _setupEventListeners() {
    _socket?.on('webrtc_answer', (data) {
      logger.i('Received WebRTC answer from server');
      _isConnected = true;
    });

    _socket?.on('webrtc_ice_ack', (data) {
      logger.i('ICE candidate acknowledged by server');
    });

    _socket?.on('webrtc_translation', (data) {
      logger.i('Received translation result: ${data['spanish_text']}');
      logger.i('Received audio data of length: ${data['audio']?.length ?? 0}');

      // Check if this is original audio (timeout fallback)
      bool isOriginalAudio = data['is_original_audio'] == true;
      if (isOriginalAudio) {
        logger.w('Translation timed out, received original audio back');
      }

      if (onTranscription != null) {
        onTranscription!(data['english_text']);
      }

      if (onTranslation != null) {
        onTranslation!(data['spanish_text']);
      }

      if (onAudioReceived != null && data['audio'] != null) {
        onAudioReceived!(data['audio']);
      }
    });

    _socket?.on('webrtc_error', (data) {
      logger.e('WebRTC error: ${data['error']}');
      if (onError != null) {
        onError!(data['error']);
      }
    });
  }

  // Start a WebRTC-like call
  Future<bool> startCall() async {
    if (!_isInitialized) {
      logger.e('WebRTC helper not initialized');
      return false;
    }

    try {
      // Get user media permission (but we won't use actual WebRTC)
      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});

      // For web, get the native media stream
      if (_localStream != null) {
        // Get the native media stream for recording - use dynamic to safely access jsStream
        dynamic nativeStream = _localStream;
        try {
          _webStream = nativeStream.jsStream as html.MediaStream?;
        } catch (e) {
          logger.e('Error accessing native stream: $e');
        }
      }

      // Send a fake offer to the server to initiate the connection
      _socket?.emit('webrtc_offer', {
        'type': 'offer',
        'sdp':
            'v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\na=msid-semantic:WMS *\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:111 opus/48000/2\r\na=setup:actpass\r\na=mid:0\r\na=sendrecv\r\n'
      });

      // Send a fake ICE candidate
      _socket?.emit('webrtc_ice_candidate', {
        'candidate':
            'candidate:0 1 UDP 2122252543 192.168.1.100 12345 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0
      });

      logger.i('WebRTC-like call initiated');
      return true;
    } catch (e) {
      logger.e('Error starting WebRTC-like call: $e');
      return false;
    }
  }

  // End the call
  Future<void> endCall() async {
    if (_isRecording) {
      await stopRecording();
    }

    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;
    _webStream = null;
    _isConnected = false;

    logger.i('WebRTC-like call ended');
  }

  // Start recording and streaming audio
  Future<void> startRecording() async {
    if (_isRecording) return;
    if (_webStream == null) {
      logger.e('No web media stream available');
      return;
    }

    _audioChunks = [];

    try {
      // Create MediaRecorder
      _webRecorder =
          html.MediaRecorder(_webStream!, {'mimeType': 'audio/webm'});

      // Set up event listeners
      _webRecorder!.addEventListener('dataavailable', (event) {
        final dynamic e = event;
        final blob = e.data as html.Blob;
        _audioChunks.add(blob);
        logger.i('Recorded audio chunk: ${blob.size} bytes');
      });

      // Start recording with 3-second intervals
      _webRecorder!.start(3000); // 3 seconds chunks
      _isRecording = true;

      logger.i('Started recording audio for WebRTC-like streaming');
    } catch (e) {
      logger.e('Error starting audio recording: $e');
    }
  }

  // Stop recording
  Future<void> stopRecording() async {
    if (!_isRecording || _webRecorder == null) return;

    try {
      // Stop the recorder
      final completer = Completer<void>();

      _webRecorder!.addEventListener('stop', (event) {
        _processAudioChunks();
        completer.complete();
      });

      _webRecorder!.stop();
      await completer.future;

      _isRecording = false;
      logger.i('Stopped recording audio');
    } catch (e) {
      logger.e('Error stopping audio recording: $e');
    }
  }

  // Process recorded audio chunks
  Future<void> _processAudioChunks() async {
    if (_audioChunks.isEmpty) {
      logger.w('No audio chunks to process');
      return;
    }

    try {
      // Combine chunks into a single blob
      final blob = html.Blob(_audioChunks, 'audio/webm');
      logger.i('Processing audio blob: ${blob.size} bytes');

      // Convert blob to base64
      final reader = html.FileReader();
      final completer = Completer<Uint8List>();

      reader.onLoad.listen((event) {
        final result = reader.result as dynamic;
        final uint8List = Uint8List.fromList(result);
        completer.complete(uint8List);
      });

      reader.readAsArrayBuffer(blob);
      final audioBytes = await completer.future;

      // Store raw audio for direct playback
      rawAudioData = audioBytes;

      // Notify about raw audio capture
      if (onRawAudioCaptured != null) {
        onRawAudioCaptured!(audioBytes);
      }

      // Convert to base64 for sending
      final base64Audio = base64Encode(audioBytes);

      // Send audio to server
      _socket?.emit('webrtc_audio', {
        'sessionId': 'webrtc-${DateTime.now().millisecondsSinceEpoch}',
        'audio': base64Audio
      });

      logger.i('Sent audio chunk to server: ${base64Audio.length} chars');

      // Clear chunks
      _audioChunks = [];
    } catch (e) {
      logger.e('Error processing audio chunks: $e');
    }
  }

  // Public getters
  bool get isConnected => _isConnected;
  bool get isRecording => _isRecording;
  MediaStream? get localStream => _localStream;
}