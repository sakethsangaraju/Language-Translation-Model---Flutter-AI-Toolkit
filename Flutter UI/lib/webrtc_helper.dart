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
  // WebRTC connection
  RTCPeerConnection? _peerConnection;
  // Callbacks
  Function(String)? onTranscription;
  Function(String)? onTranslation;
  Function(String)? onError;
  Function(String)? onAudioReceived;
  Function(Uint8List)? onRawAudioCaptured; //for raw audio
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

  // Set up socket.io event listeners
  void _setupEventListeners() {
    _socket?.on('webrtc_answer', (data) async {
      logger.i('Received WebRTC answer from server');

      try {
        // Handle server's answer by setting the remote description
        final answer = RTCSessionDescription(data['sdp'], data['type']);
        await _peerConnection?.setRemoteDescription(answer);
        logger.i('Remote description set from answer');
        _isConnected = true;
      } catch (e) {
        logger.e('Error setting remote description: $e');
      }
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

  // Start a WebRTC call
  Future<bool> startCall() async {
    if (!_isInitialized) {
      logger.e('WebRTC helper not initialized');
      return false;
    }
    try {
      // Configure RTCPeerConnection with STUN server
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ]
      };

      // Create peer connection with STUN server
      _peerConnection = await createPeerConnection(configuration);

      // Add ICE connection state change listener
      _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
        logger.i('ICE connection state changed: $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          // Insert fallback logic here (e.g., emit a fallback event or call a fallback method)
          logger.w('ICE connection failed - initiating fallback mechanism');
          // (Optionally, set a flag or invoke a callback: onError?.call('Connection failed, using Socket.IO fallback');)
        }
      };

      // Set up remote track handling
      _peerConnection?.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'audio') {
          logger.i('Got remote audio track from server');
          // The browser will automatically play the audio since we have an audio track
          // No need to explicitly set up an audio renderer
        }
      };

      // Alternative handler for older implementations
      _peerConnection?.onAddStream = (MediaStream stream) {
        logger.i('Got remote stream from server');
        // The audio will play automatically in the browser
      };

      // Get user media permission
      final mediaConstraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true
        },
        'video': false
      };
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);

      // Add local audio tracks to peer connection
      _localStream?.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      // For web, get the native media stream for recording
      if (_localStream != null) {
        // Get the native media stream for recording - use dynamic to safely access jsStream
        dynamic nativeStream = _localStream;
        try {
          _webStream = nativeStream.jsStream as html.MediaStream?;
        } catch (e) {
          logger.e('Error accessing native stream: $e');
        }
      }

      // Listen for local ICE candidates to send them to the server
      _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
        logger.i('Generated ICE candidate: ${candidate.candidate}');
        _socket?.emit('webrtc_ice_candidate', {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex
        });
      };

      // Create an offer with offerToReceiveAudio option
      RTCSessionDescription offer =
          await _peerConnection!.createOffer({'offerToReceiveAudio': true});

      // Set local description
      await _peerConnection!.setLocalDescription(offer);

      // Send the offer to the server
      _socket?.emit('webrtc_offer', {'type': offer.type, 'sdp': offer.sdp});

      // Start a timer for fallback logic
      Timer(Duration(seconds: 10), () {
        if (!_isConnected) {
          logger.w('WebRTC connection timed out, falling back to Socket.IO');
          // Invoke fallback mechanism
          fallbackToSocketIO();
        }
      });

      // Set up handler for remote ICE candidates
      _socket?.on('webrtc_ice_candidate', (candidateData) async {
        try {
          final candidate = RTCIceCandidate(
            candidateData['candidate'],
            candidateData['sdpMid'],
            candidateData['sdpMLineIndex'],
          );
          await _peerConnection?.addCandidate(candidate);
          logger.i('Added remote ICE candidate');
        } catch (e) {
          logger.e('Error adding ICE candidate: $e');
        }
      });

      logger.i('WebRTC call initiated');
      return true;
    } catch (e) {
      logger.e('Error starting WebRTC call: $e');
      return false;
    }
  }

  // End the call
  Future<void> endCall() async {
    if (_isRecording) {
      await stopRecording();
    }

    _localStream?.getTracks().forEach((track) => track.stop());
    await _peerConnection?.close();
    _peerConnection = null;
    _localStream = null;
    _webStream = null;
    _isConnected = false;

    logger.i('WebRTC call ended');
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
      //MediaRecorder
      _webRecorder =
          html.MediaRecorder(_webStream!, {'mimeType': 'audio/webm'});

      //event listeners
      _webRecorder!.addEventListener('dataavailable', (event) {
        final dynamic e = event;
        final blob = e.data as html.Blob;
        _audioChunks.add(blob);
        logger.i('Recorded audio chunk: ${blob.size} bytes');
      });

      // starting the recording with 3 second intervals
      _webRecorder!.start(3000); //chunks
      _isRecording = true;

      logger.i('Started recording audio for WebRTC-like streaming');
    } catch (e) {
      logger.e('Error starting audio recording: $e');
    }
  }

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

  // Process audio chunks
  Future<void> _processAudioChunks() async {
    if (_audioChunks.isEmpty) {
      logger.w('No audio chunks to process');
      return;
    }
    try {
      //chunks into a single blob
      final blob = html.Blob(_audioChunks, 'audio/webm');
      logger.i('Processing audio blob: ${blob.size} bytes');
      // blob to base64
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
      // base64 for sending
      final base64Audio = base64Encode(audioBytes);
      // Send audio to server
      _socket?.emit('webrtc_audio', {
        'sessionId': 'webrtc-${DateTime.now().millisecondsSinceEpoch}',
        'audio': base64Audio
      });
      logger.i('Sent audio chunk to server: ${base64Audio.length} chars');
      // lets clear the chunks
      _audioChunks = [];
    } catch (e) {
      logger.e('Error processing audio chunks: $e');
    }
  }

  // Public getters
  bool get isConnected => _isConnected;
  bool get isRecording => _isRecording;
  MediaStream? get localStream => _localStream;

  // Fallback mechanism when WebRTC fails
  void fallbackToSocketIO() {
    logger.i('Initiating Socket.IO fallback for audio transfer');

    // Notify the app about fallback
    if (onError != null) {
      onError!('WebRTC connection failed, using Socket.IO fallback');
    }

    // Clean up WebRTC resources
    _peerConnection?.close();

    // Fallback flag - app can check this to know we're in fallback mode
    _isConnected = false;

    // Continue with Socket.IO based communication
    // The app will use the regular Socket.IO mechanisms for audio transfer
  }
}
