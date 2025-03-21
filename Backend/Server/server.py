import eventlet
eventlet.monkey_patch()

import os
from dotenv import load_dotenv
load_dotenv()

import base64
import random
import time
import logging
import json
import webrtcvad
import wave
import tempfile
import re
import uuid
import threading
import queue
import numpy as np
import struct
import concurrent.futures
import asyncio
from fractions import Fraction
import av
from collections import deque

# Import aiortc components
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, RTCConfiguration, RTCIceServer
from aiortc.contrib.media import MediaStreamTrack, MediaBlackhole
from aiortc.mediastreams import MediaStreamError, AudioStreamTrack

from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from werkzeug.utils import secure_filename

from google import genai
from google.genai import types

# logging with more details for debugging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logging.getLogger('engineio').setLevel(logging.WARNING)
logging.getLogger('socketio').setLevel(logging.WARNING)
logging.getLogger('werkzeug').setLevel(logging.WARNING)
# Flask app + CORS 
app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

# Server configuration
PORT = 8009
UPLOAD_FOLDER = os.path.join(os.path.dirname(__file__), 'uploads')
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)


# Maximum content length (10MB)
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

# Store WebRTC client sessions
webrtc_clients = {}
# Store active WebRTC peer connections
webrtc_peer_connections = {}
# Store TTS audio queues for each session
tts_audio_queues = {}

# --- Configure Gemini ---
# Get API key from environment variables
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
if not GEMINI_API_KEY or GEMINI_API_KEY == "YOUR_KEY_HERE":
    logging.warning("GEMINI_API_KEY not set or invalid. Speech translation will not work, but test mode will.")
    TEST_MODE = True
else:
    logging.info("GEMINI_API_KEY found. Full functionality available.")
    TEST_MODE = False

# The newer Gemini SDK doesn't use configure() anymore
# Instead, we create a client directly
try:
    client = genai.Client(api_key=GEMINI_API_KEY)
    logging.info("Gemini client created successfully")
except Exception as e:
    logging.error(f"Error creating Gemini client: {e}")
    client = None
    TEST_MODE = True

# API key in environment variable
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    raise ValueError("GEMINI_API_KEY environment variable not set")

# We'll create a global model instance after the TranslationModel class is defined

# ------------------------------------------------------------VAD Config -----------------------------------
# WebRTC VAD is used to detect when speech starts and ends
vad = webrtcvad.Vad(2)                          # aggressiveness level (0-3)
SAMPLE_RATE = 16000                             # 16kHz as required by Gemini and VAD
FRAME_DURATION_MS = 30                          # 30ms frames for VAD
FRAME_SIZE = int(SAMPLE_RATE * FRAME_DURATION_MS / 1000)
SILENCE_THRESHOLD = 15                          # How many silent frames before considering speech ended
webrtc_peers = {}# Store active WebRTC peer connections

audio_processing_queue = queue.Queue()# Audio processing queue for WebRTC

# Handle WebRTC offer
@socketio.on('webrtc_offer')
def handle_webrtc_offer(data):
    """Handle WebRTC offers from clients using aiortc"""
    client_id = request.sid
    logging.info(f"Received WebRTC offer from {client_id}")
    
    try:
        # Parse the SDP offer
        offer_data = data.get('sdp')
        offer_type = data.get('type')
        if not offer_data or not offer_type:
            logging.error(f"Invalid WebRTC offer from {client_id}: missing sdp or type")
            emit('webrtc_error', {'error': 'Invalid offer: missing sdp or type'})
            return
            
        offer = RTCSessionDescription(sdp=offer_data, type=offer_type)
        
        # Create peer connection with STUN/TURN servers
        config = RTCConfiguration(
            iceServers=[
                RTCIceServer(
                    urls=["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]
                ),
                RTCIceServer(
                    urls=["turn:turn.stanfy.com:3478"],
                    username="test",
                    credential="test"
                )
            ]
        )
        
        # Create a new peer connection
        pc = RTCPeerConnection(configuration=config)
        
        # Generate unique session ID
        session_id = f"webrtc-{int(time.time())}"
        
        # IMPORTANT: Store the peer connection immediately after creation
        # to ensure it's available for incoming ICE candidates
        current_time = time.time()
        logging.info(f"[{session_id}] [{current_time}] Storing RTCPeerConnection for client {client_id} immediately after creation")
        webrtc_peer_connections[client_id] = {
            'pc': pc,
            'session_id': session_id,
            'active': True,
            'created_at': current_time
        }
        
        logging.info(f"[{session_id}] Creating new WebRTC session for client {client_id}")
        
        # Create and add a Gemini audio track to send TTS back to client
        gemini_track = GeminiAudioTrack(session_id)
        pc.addTrack(gemini_track)
        
        # Update the peer connection info with the track
        webrtc_peer_connections[client_id]['track'] = gemini_track
        
        # Set up ICE candidate event handler
        @pc.on("icecandidate")
        def on_ice_candidate(candidate):
            logging.info(f"[{session_id}] New ICE candidate: {candidate.sdpMid}")
            # Send the ICE candidate to the client
            emit('webrtc_ice_candidate', {
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex
            })
        
        # Log ICE connection state changes
        @pc.on("iceconnectionstatechange")
        def on_ice_connection_state_change():
            logging.info(f"[{session_id}] ICE connection state changed to: {pc.iceConnectionState}")
            conn_data = webrtc_peer_connections.get(client_id)
            if conn_data:
                conn_data['ice_state'] = pc.iceConnectionState
                
                # Mark connection as inactive if failed/disconnected
                if pc.iceConnectionState in ["failed", "closed", "disconnected"]:
                    conn_data['active'] = False
                    logging.warning(f"[{session_id}] WebRTC connection is no longer active")
                elif pc.iceConnectionState == "connected":
                    conn_data['active'] = True
                    logging.info(f"[{session_id}] WebRTC connection established")
        
        # Handle track events - this is mainly for debugging since we don't expect
        # to receive tracks from the client, just send our TTS track
        @pc.on("track")
        def on_track(track):
            logging.info(f"[{session_id}] Received track: {track.kind}")
            
            # Just to be safe, don't send the events to nowhere
            @track.on("ended")
            async def on_ended():
                logging.info(f"[{session_id}] Track ended")
        
        # Set remote description from the offer
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        async def process_offer():
            # Set the remote description from the offer
            await pc.setRemoteDescription(offer)
            
            # Create an answer
            answer = await pc.createAnswer()
            
            # Set local description from the answer
            await pc.setLocalDescription(answer)
            
            # Send the answer back to the client
            emit('webrtc_answer', {
                'sdp': pc.localDescription.sdp,
                'type': pc.localDescription.type
            })
            logging.info(f"[{session_id}] Sent WebRTC answer to client {client_id}")
            
        # Run the async code
        future = asyncio.run_coroutine_threadsafe(process_offer(), loop)
        future.result(timeout=10)  # Wait for at most 10 seconds
        
        # Store client ID for ICE candidates - mark as active WebRTC client
        webrtc_clients[client_id] = {
            'session_id': session_id,
            'webrtc_active': True
        }
        
        logging.info(f"[{session_id}] WebRTC offer handling completed for client {client_id}")
    
    except Exception as e:
        logging.error(f"Error handling WebRTC offer: {e}", exc_info=True)
        emit('webrtc_error', {'error': f'WebRTC negotiation failed: {str(e)}'})
        # Make sure we still have a way to communicate with the client
        webrtc_clients[client_id] = {
            'webrtc_active': False
        }

# Handle ICE candidates
@socketio.on('webrtc_ice_candidate')
def handle_ice_candidate(data):
    """Handle ICE candidates from clients"""
    client_id = request.sid
    current_time = time.time()
    logging.info(f"[{current_time}] Received ICE candidate from {client_id}")
    
    # Get the peer connection for this client
    conn_data = webrtc_peer_connections.get(client_id)
    if not conn_data:
        logging.warning(f"[{current_time}] Received ICE candidate but no connection found for client {client_id}")
        return
        
    if not conn_data.get('active', False):
        logging.warning(f"[{current_time}] Received ICE candidate but connection not active for client {client_id}")
        return
    
    # Log the timing information to debug race conditions
    created_at = conn_data.get('created_at', 0)
    time_since_creation = current_time - created_at
    logging.info(f"[{current_time}] Processing ICE candidate {time_since_creation:.3f} seconds after PC creation")
    
    try:
        # Extract the candidate data
        candidate = data.get('candidate')
        sdp_mid = data.get('sdpMid')
        sdp_mline_index = data.get('sdpMLineIndex')
        
        if not candidate or sdp_mid is None or sdp_mline_index is None:
            logging.error(f"Invalid ICE candidate from {client_id}: missing required fields")
            return
        
        # Add the candidate to the peer connection
        pc = conn_data['pc']
        session_id = conn_data['session_id']
        
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        async def add_candidate():
            logging.info(f"[{session_id}] [{time.time()}] Adding ICE candidate to peer connection")
            logging.info(f"[{session_id}] ICE dictionary: {{'candidate': {candidate}, 'sdpMid': {sdp_mid}, 'sdpMLineIndex': {sdp_mline_index}}}")
            await pc.addIceCandidate({
                'candidate': candidate,
                'sdpMid': sdp_mid,
                'sdpMLineIndex': sdp_mline_index
            })
            logging.info(f"[{session_id}] [{time.time()}] Successfully added ICE candidate")
        
        # Run the async code
        future = asyncio.run_coroutine_threadsafe(add_candidate(), loop)
        future.result(timeout=5)  # Wait for at most 5 seconds
        
        logging.info(f"[{session_id}] Added ICE candidate from client {client_id}")
        
        # Acknowledge receipt
        emit('webrtc_ice_ack', {'status': 'received'})
    
    except Exception as e:
        logging.error(f"Error adding ICE candidate: {e}")
        emit('webrtc_error', {'error': f'Failed to add ICE candidate: {str(e)}'})

# Handle direct audio data from WebRTC
@socketio.on('webrtc_audio')
def handle_webrtc_audio(data):
    """Handle audio data sent directly over Socket.IO"""
    client_id = request.sid
    logging.info(f"Received WebRTC audio data from {client_id}, size: {len(data['audio'])}")
    
    # Check if we have an active WebRTC connection for this client
    conn_data = webrtc_peer_connections.get(client_id, {})
    session_id = conn_data.get('session_id', f'webrtc-{int(time.time() * 1000)}')
    webrtc_active = conn_data.get('active', False)
    
    # get audio data using base 64 
    audio_base64 = data['audio']
    original_audio_b64 = data['audio']  # Store original audio for fallback
    temp_file_path = None
    
    # this is a backup to the ThreadPoolExecutor timeout)
    def timeout_handler():
        logging.warning(f"[{session_id}] Backup timeout triggered - ensuring response is sent")
        try:
            if not webrtc_active:
                # Only send socket.io response if we're not using WebRTC
                emit('webrtc_translation', {
                    'sessionId': session_id,
                    'english_text': '(Translation timed out)',
                    'spanish_text': '(Traducción agotada por tiempo)',
                    'audio': original_audio_b64,
                    'is_original_audio': True,
                    'backup_timeout': True
                })
            else:
                logging.info(f"[{session_id}] Not sending Socket.IO response - using WebRTC data channel")
        except Exception as e:
            logging.error(f"[{session_id}] Error in backup timeout handler: {e}")
    
    # Start backup timeout timer
    backup_timer = threading.Timer(18.0, timeout_handler)  # 18 seconds (slightly longer than primary timeout)
    backup_timer.daemon = True  # Allow the program to exit if this thread is still running
    backup_timer.start()
    
    try:
        # Decode base64 audio
        audio_bytes = base64.b64decode(audio_base64)
        
        # temp file for processing perhaps or just deleting 
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
            temp_file_path = temp_file.name
            
            #WAV file -- assuming 16kHz mono PCM
            with wave.open(temp_file_path, 'wb') as wf:
                wf.setnchannels(1)  # Mono
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(16000)  # 16kHz
                wf.writeframes(audio_bytes)
            
            logging.info(f"[{session_id}] Saved WebRTC audio to {temp_file_path} ({len(audio_bytes)} bytes)")
        
        # Create a simpler transcribe function that won't hang
        def safe_transcribe(audio_path, timeout=10):
            """A simplified transcription that only uses Google and has a timeout"""
            try:
                import speech_recognition as sr
                recognizer = sr.Recognizer()
                with sr.AudioFile(audio_path) as source:
                    audio_data = recognizer.record(source)
                    # Only try Google for simplicity and speed
                    text = recognizer.recognize_google(audio_data)
                    logging.info(f"[{session_id}] Transcribed with Google: {text}")
                    return text.strip()
            except Exception as e:
                logging.warning(f"[{session_id}] Transcription error: {e}")
                return "Hello, this is a test message."  # Default fallback text
        
        # translation function to be executed with a timeout
        def process_and_translate():
            try:
                # Process audio - transcribe using the simplified function
                english_text = safe_transcribe(temp_file_path)
                logging.info(f"[{session_id}] Using text for translation: {english_text}")
                
                # Get the translation
                translator = TranslationModel()
                spanish_text = translator.translate(english_text)
                logging.info(f"[{session_id}] Translated to: {spanish_text}")
                
                # Generate simple audio 
                tts_audio = generate_tts(spanish_text)
                tts_audio_b64 = base64.b64encode(tts_audio).decode('utf-8')
                
                # If we have an active WebRTC connection, feed the audio into the track
                if webrtc_active and conn_data.get('track'):
                    track = conn_data['track']
                    logging.info(f"[{session_id}] Adding TTS audio to GeminiAudioTrack queue ({len(tts_audio)} bytes)")
                    track.add_audio(tts_audio)
                    
                return {
                    'success': True,
                    'english_text': english_text,
                    'spanish_text': spanish_text,
                    'audio': tts_audio_b64
                }
            except Exception as e:
                logging.error(f"[{session_id}] Error in process_and_translate: {e}")
                return {
                    'success': False,
                    'error': str(e)
                }
        
        # use primary timeout to make sure we dont hang 
        result_sent = False
        try:
            # Use ThreadPoolExecutor to run the function with a timeout
            with concurrent.futures.ThreadPoolExecutor() as executor:
                future = executor.submit(process_and_translate)
                try:
                    result = future.result(timeout=15)  # 15 secs 
                    
                    if result['success']:
                        # If using WebRTC, just send the text results, not the audio
                        # (audio will be sent through the WebRTC track)
                        if webrtc_active:
                            logging.info(f"[{session_id}] Using WebRTC for audio - sending only text via Socket.IO")
                            emit('webrtc_translation', {
                                'sessionId': session_id,
                                'english_text': result['english_text'],
                                'spanish_text': result['spanish_text'],
                                # Omit audio as it's sent via WebRTC
                                'using_webrtc': True
                            })
                        else:
                            # Send back results via Socket.IO (fallback method)
                            emit('webrtc_translation', {
                                'sessionId': session_id,
                                'english_text': result['english_text'],
                                'spanish_text': result['spanish_text'],
                                'audio': result['audio']
                            })
                        result_sent = True
                        # Log success for debugging
                        logging.info(f"[{session_id}] Successfully processed translation: '{result['spanish_text']}'")
                    else:
                        # Handle translation failure - still return original audio
                        logging.warning(f"[{session_id}] Translation process failed: {result.get('error', 'Unknown error')}")
                        emit('webrtc_translation', {
                            'sessionId': session_id,
                            'english_text': '(Translation failed)',
                            'spanish_text': '(Error de traducción)',
                            'audio': original_audio_b64 if not webrtc_active else None,
                            'is_original_audio': True,
                            'using_webrtc': webrtc_active
                        })
                        result_sent = True
                except concurrent.futures.TimeoutError:
                    # Inner timeout - handle separately to ensure we get here
                    logging.warning(f"[{session_id}] Inner timeout occurred in future.result")
                    # This will be handled by the outer exception handler
                    raise
        except concurrent.futures.TimeoutError:
            # Timeout occurred - send back the original audio
            if not result_sent:
                logging.warning(f"[{session_id}] Translation timed out after 15 seconds")
                if not webrtc_active:
                    # Only send fallback audio via Socket.IO if not using WebRTC
                    emit('webrtc_translation', {
                        'sessionId': session_id,
                        'english_text': '(Translation timed out)',
                        'spanish_text': '(Traducción agotada por tiempo)',
                        'audio': original_audio_b64,
                        'is_original_audio': True
                    })
                else:
                    # For WebRTC, just send the status message
                    emit('webrtc_translation', {
                        'sessionId': session_id,
                        'english_text': '(Translation timed out)',
                        'spanish_text': '(Traducción agotada por tiempo)',
                        'using_webrtc': True
                    })
                result_sent = True
        except Exception as e:
            # Generic error in the executor - send back the original audio
            if not result_sent:
                logging.error(f"[{session_id}] Error in translation executor: {e}")
                emit('webrtc_translation', {
                    'sessionId': session_id,
                    'english_text': '(Translation error)',
                    'spanish_text': '(Error de traducción)',
                    'audio': original_audio_b64 if not webrtc_active else None,
                    'is_original_audio': True,
                    'using_webrtc': webrtc_active
                })
                result_sent = True
        # Cancel the backup timer if we successfully sent a result
        if result_sent:
            backup_timer.cancel()
        
        # Cleanup
        if temp_file_path:
            try:
                os.unlink(temp_file_path)
            except:
                pass
                
    except Exception as e:
        logging.error(f"[{session_id}] Error processing WebRTC audio: {e}")
        # Make sure we send a response even in case of error
        if not result_sent:
            emit('webrtc_translation', {
                'sessionId': session_id,
                'english_text': '(Processing error)',
                'spanish_text': '(Error de procesamiento)',
                'audio': original_audio_b64 if not webrtc_active else None,
                'is_original_audio': True,
                'using_webrtc': webrtc_active
            })
        
        # Cancel the backup timer
        backup_timer.cancel()
        
        # Cleanup
        if temp_file_path:
            try:
                os.unlink(temp_file_path)
            except:
                pass

# Keep the generate_tts function for basic audio generation
def generate_tts(text):
    """
    Generate TTS audio for the given text.
    Returns raw PCM audio data at 16kHz, 16-bit, mono.
    """
    try:
        # Estimate duration based on text length
        # About 100 characters per 5 seconds
        duration_seconds = max(1, len(text) / 20)  # At least 1 second
        
        # Generate a simple sine wave instead of silence
        # This makes it easier to verify that audio is being sent
        sample_rate = 16000
        t = np.linspace(0, duration_seconds, int(sample_rate * duration_seconds), False)
        
        # Generate a 440 Hz sine wave
        sine_wave = np.sin(2 * np.pi * 440 * t) * 32767  # Scale to 16-bit range
        
        # Convert to 16-bit PCM
        audio_data = bytearray()
        for sample in sine_wave:
            audio_data.extend(struct.pack('<h', int(sample)))  # Little-endian 16-bit
            
        logging.info(f"Generated {len(audio_data)} bytes of TTS audio for: {text[:30]}...")
        return bytes(audio_data)
        
    except Exception as e:
        logging.error(f"Error generating TTS: {e}")
        # Return 1 second of silence as fallback
        return bytes(16000 * 2)

@app.route('/echo', methods=['POST'])
def echo():
    """Simple echo endpoint for testing server connectivity"""
    data = request.get_json()
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    return jsonify({
        'echo': data['text'],
        'message': 'Server received your text successfully!'
    })

@app.route('/upload', methods=['POST'])
def upload_file():
    """Handle file uploads and store them in the uploads directory"""
    if 'file' not in request.files:
        return jsonify({'error': 'No file uploaded'}), 400
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400

    # add timestamp to avoid collisions
    filename = secure_filename(file.filename)
    name, ext = os.path.splitext(filename)
    timestamp = int(random.random() * 1000 + time.time() * 1000)
    saved_name = f"{name}_{timestamp}{ext}"
    saved_path = os.path.join(UPLOAD_FOLDER, saved_name)
    file.save(saved_path)

    # Return URL to access the uploaded file
    url = f"{request.host_url}uploads/{saved_name}"
    return jsonify({
        'url': url,
        'message': f'File "{saved_name}" uploaded successfully!'
    })

@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    """Serve uploaded files"""
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)


class TranslationModel:
    def __init__(self):
        api_key = os.environ.get('GEMINI_API_KEY')
        if not api_key:
            logging.warning("No GEMINI_API_KEY found. Limited functionality.")
            self.client = None
            return
            
        logging.info("GEMINI_API_KEY found. Full functionality available.")
        
        # Store the client and model name
        self.client = client  # Use the global Gemini client
        self.model_name = "gemini-1.5-pro"  # Default model
        logging.info(f"Initialized Gemini with model: {self.model_name}")
    
    def translate(self, text):
        """Translate text from English to Spanish using Gemini"""
        if not self.client:
            logging.warning("No client available for translation")
            return "Translation unavailable (no client)"
            
        try:
            import re
            
            # Direct translation prompt
            prompt = f"""
You are a translator from English to Spanish.
Respond only in valid JSON with exactly one key: "translation".
No extra text, no code blocks, no commentary.
For example:
{{"translation": "Hola"}}
Now, translate this text:
"{text}"
            """
            
            response = self.client.models.generate_content(
                model=self.model_name,
                contents=prompt,
                config=types.GenerateContentConfig(
                    max_output_tokens=512,
                    temperature=0.7,
                    top_p=0.9,
                    top_k=50
                )
            )
            response_text = response.text.strip()
            
            logging.info("Gemini translation output: %s", response_text)
            
            # Try to parse as JSON first
            try:
                parsed = json.loads(response_text)
                translation = parsed.get("translation", "").strip()
                if translation:
                    return translation
            except json.JSONDecodeError:
                logging.warning("Model did not produce valid JSON. Attempting fallback cleanup.")
            
            # If we have markdown code blocks, extract content
            if "```" in response_text:
                clean_text = re.sub(r'```.*?\n', '', response_text)
                clean_text = re.sub(r'```', '', clean_text)
                try:
                    # Try to parse as JSON if it looks like JSON
                    if clean_text.strip().startswith('{'):
                        data = json.loads(clean_text)
                        if "translation" in data:
                            return data["translation"]
                    # Return the cleaned text
                    return clean_text.strip()
                except:
                    # Just return the text if parsing fails
                    return clean_text.strip()
            
            # Remove any potential explanatory text
            response_text = re.sub(r'^(the|in spanish|translation|this translates to|translated as).*?:', '', response_text, flags=re.IGNORECASE)
            
            # Remove quotation marks if present
            response_text = response_text.strip('"\'')
            
            return response_text.strip()
        except Exception as e:
            logging.error(f"Translation error: {e}")
            return "Translation error."

@app.route('/test_translation', methods=['POST'])
def test_translation():
    data = request.get_json()
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    text = data['text']
    logging.info("Test translation request: %s", text)
    try:
        translation = model.translate(text)
        return jsonify({
            'original': text,
            'translation': translation
        })
    except Exception as e:
        logging.error("Translation test error: %s", e)
        return jsonify({'error': f'Translation failed: {str(e)}'}), 500

# ----------------- Gemini Translation -----------------
class Gemini:
    def __init__(self, model='gemini-2.0-flash'):
        self.client = client
        self.model = model
        self.connection = True
        
    def conversation(self, text):
        if not self.connection:
            raise ConnectionError("Server disconnected")
        if not text:
            return "No message received"
            
        try:
            import re  # Import re at the top level of the function
            
            # Direct translation prompt that asks for just the translation without explanation
            prompt = f"""
You are a translator from English to Spanish.
Respond only in valid JSON with exactly one key: "translation".
No extra text, no code blocks, no commentary.
For example:
{{"translation": "Hola"}}
Now, translate this text:
"{text}"
            """
            
            response = self.model.generate_content(prompt)
            response_text = response.text.strip()
            
            logging.info("Gemini raw output:\n%s", response_text)
            
            # Try to parse as JSON first
            try:
                parsed = json.loads(response_text)
                translation = parsed.get("translation", "").strip()
                if translation:
                    return translation
            except json.JSONDecodeError:
                logging.warning("Model did not produce valid JSON. Attempting fallback cleanup.")
            
            # If we have markdown code blocks, extract content
            if "```" in response_text:
                clean_text = re.sub(r'```.*?\n', '', response_text)
                clean_text = re.sub(r'```', '', clean_text)
                try:
                    # Try to parse as JSON if it looks like JSON
                    if clean_text.strip().startswith('{'):
                        data = json.loads(clean_text)
                        if "translation" in data:
                            return data["translation"]
                    # Return the cleaned text
                    return clean_text.strip()
                except:
                    # Just return the text if parsing fails
                    return clean_text.strip()
            
            # Remove any potential explanatory text like "The translation is:"
            response_text = re.sub(r'^(the|in spanish|translation|this translates to|translated as).*?:', '', response_text, flags=re.IGNORECASE)
            
            # Remove quotation marks if present
            response_text = response_text.strip('"\'')
            
            return response_text.strip()
        except Exception as e:
            logging.error(f"Gemini error: {e}")
            return "Translation error."

    async def transcribe_audio(self, audio_path):
        """Transcribe audio to text using Whisper API or a cloud service"""
        try:
            # For now, use a simple fallback transcription function
            return transcribe_audio(audio_path)
        except Exception as e:
            logging.error(f"Transcription error: {e}")
            return "Failed to transcribe audio"

    def translate(self, text):
        try:
            import re  # Import re at the top level of the function
            
            # Direct translation prompt that asks for just the translation
            prompt = f"""
You are a translator from English to Spanish.
Respond only in valid JSON with exactly one key: "translation".
No extra text, no code blocks, no commentary.
For example:
{{"translation": "Hola"}}
Now, translate this text:
"{text}"
            """
            
            response = self.client.models.generate_content(
                model=self.model,
                contents=prompt,
                config=types.GenerateContentConfig(
                    max_output_tokens=512,
                    temperature=0.7,
                    top_p=0.9,
                    top_k=50)
            )
            raw_output = response.text.strip()
            logging.info("Gemini raw output:\n%s", raw_output)
            
            if not raw_output:
                logging.warning("Model output is empty.")
                return "Translation error."
                
            # Try to parse as JSON first
            try:
                parsed = json.loads(raw_output)
                translation = parsed.get("translation", "").strip()
                if translation:
                    logging.info("Parsed translation: %s", translation)
                    return translation
            except json.JSONDecodeError:
                logging.warning("Model did not produce valid JSON. Attempting fallback cleanup.")
            
            # Handle case where response contains markdown code fences
            if "```" in raw_output:
                # Extract the content from between code fences
                content_match = re.search(r'```(?:json|)?\s*(.*?)\s*```', raw_output, re.DOTALL)
                if content_match:
                    raw_output = content_match.group(1).strip()
                    # Try parsing the extracted content as JSON
                    try:
                        parsed = json.loads(raw_output)
                        if "translation" in parsed:
                            return parsed["translation"]
                    except:
                        pass
            
            # Final cleanup for any non-JSON response
            fallback = re.sub(r'(\"?translation\"?:?\s*)', '', raw_output, flags=re.IGNORECASE)
            fallback = fallback.strip('"\' \n:{}')
            return fallback if fallback else "Translation error."
                
        except Exception as e:
            logging.error(f"Gemini error: {e}")
            return "Translation error."
            
    async def text_to_speech(self, text):
        """Generate speech from text using a TTS service"""
        try:
            # For now, use a simple TTS function
            return generate_tts(text)
        except Exception as e:
            logging.error(f"TTS error: {e}")
            return b""  # Return empty bytes

# Create a global model instance
model = None
if GEMINI_API_KEY:
    try:
        model = TranslationModel()
        logging.info("Translation model initialized successfully")
    except Exception as e:
        logging.error(f"Error initializing translation model: {e}")
        TEST_MODE = True
else:
    logging.warning("No API key provided, running in test mode")
    TEST_MODE = True

@socketio.on('connect')
def handle_connect():
    """Handle SocketIO client connections"""
    logging.info("SocketIO client connected")
    emit('connected', {'data': 'Connected to server'})

@socketio.on('translate')
def handle_translate(data):
    """Handle text translation requests via WebSocket"""
    text = data.get('text','')
    sid = data.get('sessionId','')
    logging.info(f"Translation request via WebSocket: {text}")
    
    if not text:
        logging.warning("Empty text received for translation")
        emit('translation_error', {'sessionId': sid, 'error': 'No text provided'})
        return
    
    try:
        # Process the translation
        result = model.translate(text)
        logging.info(f"Translation result: {result}")
        
        # Send back result
        emit('translation_final', {'sessionId': sid, 'data': result})
        logging.info(f"Translation sent to client via translation_final event")
    except Exception as e:
        logging.error(f"Error in translation: {e}", exc_info=True)
        emit('translation_error', {'sessionId': sid, 'error': str(e)})

class VADProcessor:
    """Process audio chunks and detect voice activity using WebRTC VAD"""
    
    def __init__(self, session_id):
        """Initialize with session ID for tracking"""
        self.session_id = session_id
        self.is_speaking = False
        self.buffer = bytearray()
        self.silence_frames = 0
        logging.info(f"VAD processor initialized for session: {session_id}")

    def process_audio(self, audio_chunk):
        """Process an audio chunk, detect speech, and buffer it"""
        frames = []
        
        # Split audio chunk into VAD-sized frames
        for i in range(0, len(audio_chunk), FRAME_SIZE*2):
            if i+FRAME_SIZE*2 <= len(audio_chunk):
                frames.append(audio_chunk[i:i+FRAME_SIZE*2])

        for frame in frames:
            # Check if frame contains speech
            try:
                speech = vad.is_speech(frame, SAMPLE_RATE)
            except Exception as e:
                logging.error(f"VAD error: {e}")
                continue
                
            # Track speaking state transitions
            if speech and not self.is_speaking:
                self.is_speaking = True
                self.silence_frames = 0
                logging.info(f"{self.session_id}: Speech started")
            
            if not speech and self.is_speaking:
                self.silence_frames += 1
                if self.silence_frames >= SILENCE_THRESHOLD:
                    self.is_speaking = False
                    logging.info(f"{self.session_id}: Speech ended after {self.silence_frames} silent frames")
                    out = bytes(self.buffer)
                    buffer_size = len(self.buffer)
                    self.buffer.clear()
                    logging.info(f"{self.session_id}: Returning speech segment of {buffer_size} bytes")
                    return True, out

            # Buffer speech frames
            if self.is_speaking:
                self.buffer.extend(frame)

        return False, None

def resample_audio(audio_bytes, from_rate=48000, to_rate=16000):
    """Resample audio from one rate to another"""
    try:
        from scipy import signal
        
        # Convert bytes to numpy array
        audio_array = np.frombuffer(audio_bytes, dtype=np.int16)
        
        # Calculate resampling ratio
        ratio = to_rate / from_rate
        # Calculate new length
        new_length = int(len(audio_array) * ratio)
        
        # Resample
        resampled = signal.resample(audio_array, new_length)
        
        # Convert back to int16
        resampled = resampled.astype(np.int16)
        
        # Convert back to bytes
        result = resampled.tobytes()
        logging.debug(f"Resampled audio from {len(audio_bytes)} bytes to {len(result)} bytes")
        return result
    except ImportError:
        logging.warning("scipy not available, skipping resampling")
        return audio_bytes
    except Exception as e:
        logging.error(f"Error resampling audio: {e}")
    return audio_bytes

async def process_and_respond(session_id, audio_data, channel):
    """Process audio data, transcribe, translate, and send response"""
    try:
        logging.info(f"[{session_id}] Processing audio segment of {len(audio_data)} bytes")
        
        # Check if we're in test mode (no valid API key)
        if TEST_MODE:
            logging.info(f"[{session_id}] TEST MODE - Skipping transcription and translation")
            
            try:
                # Generate a test tone using gTTS
                from gtts import gTTS
                from io import BytesIO
                
                test_message = "This is a test. El servidor está funcionando en modo de prueba."
                logging.info(f"[{session_id}] Generating test TTS message")
                
                tts = gTTS(text=test_message, lang='es')
                buf = BytesIO()
                tts.write_to_fp(buf)
                buf.seek(0)
                
                # Send test audio back to the client
                audio_b64 = base64.b64encode(buf.read()).decode('utf-8')
                await channel.emit('translation_result', {
                    'sessionId': session_id,
                    'english_text': 'This is a test.',
                    'spanish_text': 'El servidor está funcionando en modo de prueba.',
                    'audio': audio_b64
                })
                return
            except Exception as e:
                logging.error(f"[{session_id}] Error generating test message: {e}")
                # Fall through to sending a simple response
                await channel.emit('translation_result', {
                    'sessionId': session_id,
                    'english_text': 'Test mode active',
                    'spanish_text': 'Modo de prueba activo',
                    'audio': ''
                })
                return
                
        # Regular processing with Gemini API below
        # Transcribe audio to English text
        eng_text = await model.transcribe_audio(audio_data)
        logging.info(f"[{session_id}] STT -> {eng_text}")
        
        if not eng_text or eng_text == "No speech detected" or eng_text == "Failed to transcribe audio" or eng_text == "Audio too short":
            logging.warning(f"[{session_id}] No valid transcription, skipping translation")
            if channel.readyState == "open":
                channel.send(json.dumps({
                    "english_text":"No speech detected",
                    "spanish_text":"No se detectó voz",
                    "error": "No valid transcription"
                }))
            return
        
        # English text to Spanish traNSLATION
        spa_text = model.translate(eng_text)
        logging.info(f"[{session_id}] Trans -> {spa_text}")
        # Convert Spanish text to speech
        logging.info(f"[{session_id}] Generating TTS for: {spa_text}")
        tts_b64 = await model.text_to_speech(spa_text)
        if tts_b64:
            logging.info(f"[{session_id}] Successfully generated TTS (base64 length: {len(tts_b64)})")
        else:
            logging.warning(f"[{session_id}] Failed to generate TTS")
        if channel.readyState == "open":
            # Send response back to client
            msg = json.dumps({
                "audio": tts_b64,
                "english_text": eng_text,
                "spanish_text": spa_text
            })
            logging.info(f"[{session_id}] Sending response with audio: {bool(tts_b64)}")
            channel.send(msg)
            logging.info(f"[{session_id}] Sent TTS over datachannel")
        else:
            logging.error(f"[{session_id}] Data channel not open, cannot send response")
    except Exception as e:
        logging.error(f"Error in process_and_respond: {e}", exc_info=True)
        if channel and channel.readyState == "open":
            channel.send(json.dumps({
                "error": str(e),
                "english_text": "Error processing audio",
                "spanish_text": "Error al procesar el audio"
            }))

@app.route('/offer', methods=['POST'])
async def offer():
    """Handle WebRTC offer from client"""
    data = request.get_json()
    if not data:
        return jsonify({'error': 'No SDP provided'}), 400

    try:
        # Parse the SDP offer
        offer = RTCSessionDescription( # type: ignore
            sdp=data['sdp'],
            type=data['type']
        )

        logging.info(f"Received SDP offer")

        # Create peer connection with network options
        config = RTCConfiguration( # type: ignore
            iceServers=[
                RTCIceServer(urls=[ # type: ignore
                    "stun:stun.l.google.com:19302",
                    "stun:stun1.l.google.com:19302",
                ]),
                # Add a free TURN server (limited bandwidth but should help for testing)
                RTCIceServer( # type: ignore
                    urls=["turn:turn.stanfy.com:3478"],
                    username="test",
                    credential="test"
                )
            ],
        )
        # Create a new peer connection
        pc = RTCPeerConnection(configuration=config) # type: ignore
        # Force IPv4 usage specifically for browser testing
        pc._host_candidates = ["127.0.0.1"] 

        # Enhance logging for connection establishment
        logging.info("WebRTC peer connection created with config: %s", config)
        logging.info("Using forced host candidates: %s", pc._host_candidates)

        # Generate unique session ID
        session_id = f"webrtc-{int(time.time())}"
        logging.info(f"Creating new WebRTC session: {session_id}")
        
        # Initialize VAD processor
        vad_proc = VADProcessor(session_id)
        channel_ref = None
        
        # Handle data channel creation
        @pc.on("datachannel")
        def on_datachannel(channel):
            nonlocal channel_ref
            logging.info(f"[{session_id}] Data channel established: {channel.label}")
            channel_ref = channel
            
            @channel.on("message")
            def on_message(message):
                logging.info(f"[{session_id}] Received message on datachannel: {message}")
        
        # Create custom audio track that processes audio with VAD
        class VADTrack(MediaStreamTrack): # type: ignore
            kind = "audio"
            async def recv(self):
                frame = await super().recv()
                audio_bytes = frame.to_ndarray().tobytes()
                audio_bytes = resample_audio(audio_bytes, 48000, 16000)
                done, segment = vad_proc.process_audio(audio_bytes)
                if done and segment and channel_ref:
                    # Process detected speech segment
                    logging.info(f"[{session_id}] Speech segment detected, length: {len(segment)} bytes")
                    asyncio.create_task(process_and_respond(session_id, segment, channel_ref)) # type: ignore
                return frame

        # Handle incoming media tracks
        @pc.on("track")
        def on_track(track):
            logging.info(f"[{session_id}] Track received: {track.kind}")
            if track.kind == "audio":
                logging.info(f"[{session_id}] Adding VAD track in response to audio track")
                pc.addTrack(VADTrack())

        # Monitor ICE connection state changes
        @pc.on("iceconnectionstatechange")
        def on_ice():
            state = pc.iceConnectionState
            logging.info(f"[{session_id}] ICE connection state changed: {state}")
            
            if state == "connected":
                logging.info(f"[{session_id}] WebRTC connected successfully!")
            elif state == "failed":
                logging.error(f"[{session_id}] WebRTC connection failed")
                # Log detailed information about candidates for debugging
                try:
                    candidates = pc.getLocalCandidates()
                    logging.info(f"[{session_id}] Local candidates: {[c.sdpMLineIndex for c in candidates]}")
                    logging.info(f"[{session_id}] Using host candidates: {pc._host_candidates}")
                except Exception as e:
                    logging.error(f"Error getting local candidates: {e}")

        # Add ICE candidate handlers for detailed debugging
        @pc.on("icecandidateerror") 
        def on_ice_error(error):
            logging.error(f"[{session_id}] ICE candidate error: {error}")
            
        # Log all gathered ICE candidates
        def on_candidate_success(candidate):
            logging.info(f"[{session_id}] ICE candidate gathered: {candidate.candidate}")
            
        pc.on("icecandidate", on_candidate_success)

        # Set the remote description from the offer
        logging.info(f"[{session_id}] Setting remote description (offer)")
        await pc.setRemoteDescription(offer)
        
        # Create an answer
        answer = await pc.createAnswer()
        logging.info(f"[{session_id}] Created answer, setting local description")
        await pc.setLocalDescription(answer)

        # Monitor ICE gathering progress
        @pc.on("icegatheringstatechange")
        def on_ice_gathering():
            state = pc.iceGatheringState
            logging.info(f"[{session_id}] ICE gathering state changed: {state}")

        # Wait for server to finish ICE gathering
        ice_gather_start = time.time()
        ice_gathering_complete = False
        while not ice_gathering_complete:
            if pc.iceGatheringState == "complete":
                ice_gathering_complete = True
                logging.info(f"[{session_id}] ICE gathering completed")
            elif time.time() - ice_gather_start > 5:  # 5 second timeout
                logging.warning(f"[{session_id}] ICE gathering timed out, proceeding with available candidates")
                break
            else:
                await asyncio.sleep(0.1) # type: ignore

        logging.info(f"[{session_id}] Sending SDP answer to client")
        
        # Make sure we have the final SDP with all candidates
        answer_dict = {
            "sdp": pc.localDescription.sdp,
            "type": pc.localDescription.type
        }
        logging.debug(f"[{session_id}] SDP answer: {answer_dict}")

        # Return the SDP answer
        return jsonify(answer_dict)
    except Exception as e:
        logging.error(f"Offer error: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

# ----------------- WebSocket Handlers -----------------
@socketio.on('audio_chunk')
def handle_audio_chunk(data):
    try:
        # Extract data from the request
        session_id = data.get('sessionId', 'unknown')
        base64_audio = data.get('audio', '')
        
        logging.info(f"[{session_id}] Received audio chunk: {len(base64_audio)} bytes")
        
        # Ensure base64 is properly padded before decoding
        while len(base64_audio) % 4 != 0:
            base64_audio += '='
        
        try:
            # Decode the base64 audio data
            audio_bytes = base64.b64decode(base64_audio)
        except Exception as e:
            logging.error(f"[{session_id}] Error decoding audio: {e}")
            emit('audio_error', {
                'sessionId': session_id,
                'error': f"Failed to decode audio: {str(e)}",
                'english_text': 'Audio encoding error',
                'spanish_text': 'Error de codificación de audio'
            })
            return
        
        # Sanity check - if audio is too small, likely not valid
        if len(audio_bytes) < 1000:  # More realistic threshold (1KB)
            logging.warning(f"[{session_id}] Audio chunk too small ({len(audio_bytes)} bytes), may not contain valid audio")
            emit('audio_error', {
                'sessionId': session_id,
                'error': 'Audio too small or invalid',
                'english_text': 'No valid audio detected',
                'spanish_text': 'No se detectó audio válido'
            })
            return
        
        # Process the audio synchronously instead of using asyncio
        # Save the audio segment to a temporary file in WAV format
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
            temp_file.write(audio_bytes)
            temp_file_path = temp_file.name
        
        # Log the file size for debugging
        logging.info(f"Saved audio segment to {temp_file_path} ({len(audio_bytes)} bytes)")
        
        # Step 1: Transcribe the audio to text
        try:
            english_text = transcribe_audio(temp_file_path)
            if not english_text:
                logging.warning(f"[{session_id}] No transcription result")
                socketio.emit('audio_error', {
                    'sessionId': session_id,
                    'error': 'Could not transcribe audio',
                    'english_text': 'No speech detected',
                    'spanish_text': 'No se detectó voz'
                })
                os.unlink(temp_file_path)  # Clean up the temp file
                return
            
            logging.info(f"Transcribed text: {english_text}")
            logging.info(f"[{session_id}] STT -> {english_text}")
            
            # Step 2: Translate the text from English to Spanish
            spanish_text = model.translate(english_text)
            if not spanish_text or spanish_text == "Translation error.":
                logging.warning(f"[{session_id}] Translation failed")
                socketio.emit('audio_error', {
                    'sessionId': session_id,
                    'error': 'Translation failed',
                    'english_text': english_text,
                    'spanish_text': 'Error de traducción'
                })
                os.unlink(temp_file_path)  # Clean up the temp file
                return
            
            logging.info(f"[{session_id}] Trans -> {spanish_text}")
            
            # Step 3: Generate TTS for the Spanish text
            logging.info(f"[{session_id}] Generating TTS for: {spanish_text}")
            
            # Use gTTS 
            try:
                from gtts import gTTS
                from io import BytesIO
                
                tts = gTTS(text=spanish_text, lang='es')
                buf = BytesIO()
                tts.write_to_fp(buf)
                buf.seek(0)
                audio_data = buf.read()
                audio_base64 = base64.b64encode(audio_data).decode('utf-8')
                logging.info(f"Using gTTS to synthesize: {spanish_text}")
                logging.info(f"TTS successful, generated {len(audio_data)} bytes of audio (MP3)")
            except Exception as e:
                logging.error(f"Error using gTTS: {e}")
                socketio.emit('audio_error', {
                    'sessionId': session_id,
                    'error': 'TTS generation failed',
                    'english_text': english_text,
                    'spanish_text': spanish_text
                })
                os.unlink(temp_file_path)  # Clean up the temp file
                return
            
            # Success - send the result via WebSocket
            logging.info(f"[{session_id}] Successfully generated TTS (base64 length: {len(audio_base64)})")
            socketio.emit('translation_result', {
                'sessionId': session_id,
                'english_text': english_text,
                'spanish_text': spanish_text,
                'audio': audio_base64
            })
            
            # Clean up the temp file
            os.unlink(temp_file_path)
            
        except Exception as e:
            logging.error(f"[{session_id}] Error processing audio: {e}", exc_info=True)
            socketio.emit('audio_error', {
                'sessionId': session_id,
                'error': str(e),
                'english_text': 'Server processing error',
                'spanish_text': 'Error de procesamiento del servidor'
            })
            # Try to clean up the temp file if it exists
            try:
                if 'temp_file_path' in locals():
                    os.unlink(temp_file_path)
            except:
                pass
    
    except Exception as e:
        logging.error(f"Error handling audio chunk: {e}")
        emit('audio_error', {
            'sessionId': session_id if 'session_id' in locals() else 'unknown',
            'error': str(e),
            'english_text': 'Server error',
            'spanish_text': 'Error del servidor'
        })

def transcribe_audio(audio_path):
    """
    Transcribe audio to text using Whisper or other methods
    """
    # For accurate transcription of short phrases, SpeechRecognition might be better
    try:
        import speech_recognition as sr
        recognizer = sr.Recognizer()
        with sr.AudioFile(audio_path) as source:
            audio_data = recognizer.record(source)
            try:
                # Try Google first for better accuracy with short phrases
                text = recognizer.recognize_google(audio_data)
                logging.info(f"Transcribed with Google: {text}")
                return text.strip()
            except Exception as e:
                logging.warning(f"Google Speech Recognition error: {e}")
                # Fall back to Whisper
                pass
    except Exception as e:
        logging.warning(f"SpeechRecognition failed: {e}")
    
    # Fall back to Whisper if SpeechRecognition fails
    try:
        import whisper
        try:
            model = whisper.load_model("base")
            # Use shorter audio decoding options for better accuracy with short clips
            result = model.transcribe(
                audio_path, 
                temperature=0.0,  # Lower temperature for more deterministic results
                initial_prompt="A brief voice message in English"  # Help guide the model
            )
            return result["text"].strip()
        except Exception as e:
            logging.error(f"Whisper error: {e}")
            return None
    except ImportError:
        logging.error("Neither SpeechRecognition nor Whisper available")
        return None

class GeminiAudioTrack(MediaStreamTrack):
    """
    A custom MediaStreamTrack that reads from a queue of PCM audio chunks and 
    streams them to the client as audio frames.
    """
    kind = "audio"
    
    def __init__(self, session_id):
        super().__init__()
        self.session_id = session_id
        self.queue = deque()
        # Create a queue for this session if it doesn't exist
        if session_id not in tts_audio_queues:
            tts_audio_queues[session_id] = self.queue
        else:
            self.queue = tts_audio_queues[session_id]
        
        # Audio parameters
        self._timestamp = 0
        self._frame_duration = 0.02  # 20ms per frame (standard for WebRTC)
        self._sample_rate = 48000   # WebRTC standard
        self._samples = int(self._frame_duration * self._sample_rate)
        
        # Create silence frame for when queue is empty
        silence_samples = np.zeros(self._samples, dtype=np.int16)
        self._silence_frame = self._create_audio_frame(silence_samples)
        
        logging.info(f"[{session_id}] GeminiAudioTrack initialized")
    
    def _create_audio_frame(self, samples):
        """Create an AudioFrame from PCM samples."""
        samples = np.ascontiguousarray(samples, dtype=np.int16)
        samples = samples.reshape(1, -1)  # shape => (1 channel, numSamples)
        frame = av.AudioFrame.from_ndarray(
            samples,
            format='s16p',  # signed 16-bit planar
            layout='mono'  # mono layout
        )
        frame.sample_rate = self._sample_rate
        frame.time_base = Fraction(1, self._sample_rate)
        return frame
    
    def _resample_audio(self, audio_chunk, from_rate=16000, to_rate=48000):
        """Resample audio from one rate to another"""
        try:
            # Convert bytes to numpy array if it's in bytes format
            if isinstance(audio_chunk, bytes):
                audio_array = np.frombuffer(audio_chunk, dtype=np.int16)
            else:
                audio_array = audio_chunk
                
            # Calculate resampling ratio
            ratio = to_rate / from_rate
            # Calculate new length
            new_length = int(len(audio_array) * ratio)
            
            # Resample using scipy
            from scipy import signal
            resampled = signal.resample(audio_array, new_length)
            
            # Convert back to int16
            resampled = resampled.astype(np.int16)
            
            logging.debug(f"[{self.session_id}] Resampled audio from {len(audio_array)} to {len(resampled)} samples")
            return resampled
        except Exception as e:
            logging.error(f"[{self.session_id}] Error resampling audio: {e}")
            return np.zeros(self._samples, dtype=np.int16)  # Return silence on error
    
    async def recv(self):
        """Get the next audio frame from the queue."""
        try:
            if self.queue and len(self.queue) > 0:
                # Get PCM chunk from queue
                pcm_chunk = self.queue.popleft()
                
                # Resample if needed (16kHz -> 48kHz)
                resampled_chunk = self._resample_audio(pcm_chunk)
                
                # Create frame (ensuring it has the right number of samples)
                if len(resampled_chunk) >= self._samples:
                    # If chunk is larger than our frame size, only use what we need
                    frame_samples = resampled_chunk[:self._samples]
                    # Save the rest for next time
                    if len(resampled_chunk) > self._samples:
                        self.queue.appendleft(resampled_chunk[self._samples:].tobytes())
                else:
                    # If chunk is smaller, pad with silence
                    frame_samples = np.pad(
                        resampled_chunk, 
                        (0, self._samples - len(resampled_chunk)), 
                        'constant'
                    )
                
                # Create audio frame
                frame = self._create_audio_frame(frame_samples)
                frame.pts = self._timestamp
                self._timestamp += self._samples
                
                logging.info(f"[{self.session_id}] GeminiAudioTrack sent frame: {len(frame_samples)} samples")
                return frame
            else:
                # Return silence if queue is empty
                silence_frame = self._silence_frame.clone()
                silence_frame.pts = self._timestamp
                self._timestamp += self._samples
                
                logging.debug(f"[{self.session_id}] GeminiAudioTrack sent silence frame (queue empty)")
                return silence_frame
        except Exception as e:
            logging.error(f"[{self.session_id}] Error in GeminiAudioTrack.recv: {e}")
            # Return silence frame on error
            silence_frame = self._silence_frame.clone()
            silence_frame.pts = self._timestamp
            self._timestamp += self._samples
            return silence_frame
    
    def add_audio(self, pcm_data, sample_rate=16000):
        """Add audio samples to the queue to be sent."""
        try:
            if isinstance(pcm_data, bytes):
                # Convert bytes to numpy array if needed
                samples = np.frombuffer(pcm_data, dtype=np.int16)
            else:
                samples = pcm_data
            
            logging.info(f"[{self.session_id}] Adding {len(samples)} samples to GeminiAudioTrack queue")
            
            # Don't do resampling here - we'll do it in recv() to ensure correct frame sizes
            self.queue.append(samples)
            return True
        except Exception as e:
            logging.error(f"[{self.session_id}] Error adding audio to GeminiAudioTrack: {e}")
            return False

if __name__ == '__main__':
    logging.info(f"Starting server on port {PORT}")
    try:
        socketio.run(app, host='127.0.0.1', port=PORT, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        logging.info("Server stopped by user")
    except Exception as e:
        logging.error(f"Server error: {e}", exc_info=True) 