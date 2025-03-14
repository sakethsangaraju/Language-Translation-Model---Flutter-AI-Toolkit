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

from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from werkzeug.utils import secure_filename

import google.generativeai as genai

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

# --- Configure Gemini ---
# Get API key from environment variables
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
if not GEMINI_API_KEY or GEMINI_API_KEY == "YOUR_KEY_HERE":
    logging.warning("GEMINI_API_KEY not set or invalid. Speech translation will not work, but test mode will.")
    TEST_MODE = True
else:
    logging.info("GEMINI_API_KEY found. Full functionality available.")
    TEST_MODE = False

# Configure Gemini API
genai.configure(api_key=GEMINI_API_KEY)

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
    """Handle WebRTC offers from clients (simplified version)"""
    client_id = request.sid
    logging.info(f"Received WebRTC offer from {client_id}")
    
    # We're using a simplified approach here that doesn't require the aiortc library for now 
    # Just acknowledge the offer with a dummy answer 
    emit('webrtc_answer', {
        'type': 'answer',
    })
    logging.info(f"Sent WebRTC answer to {client_id}")
    
    # Store client ID for ICE candidates
    webrtc_clients[client_id] = True

# Handle ICE candidates
@socketio.on('webrtc_ice')
def handle_ice_candidate(data):
    client_id = request.sid
    logging.info(f"Received ICE candidate from {client_id}")
    
    # Just acknowledge receipt
    if client_id in webrtc_clients:
        emit('webrtc_ice_ack', {'status': 'received'})

# Handle direct audio data from WebRTC
@socketio.on('webrtc_audio')
def handle_webrtc_audio(data):
    """Handle audio data sent directly over Socket.IO"""
    client_id = request.sid
    logging.info(f"Received WebRTC audio data from {client_id}, size: {len(data['audio'])}")
    
    # get audio data using base 64 
    audio_base64 = data['audio']
    session_id = data.get('sessionId', f'webrtc-{int(time.time() * 1000)}')
    original_audio_b64 = data['audio']  # Store original audio for fallback
    temp_file_path = None
    
    # this is a backup to the ThreadPoolExecutor timeout)
    def timeout_handler():
        logging.warning(f"Backup timeout triggered - ensuring response is sent")
        try:
            emit('webrtc_translation', {
                'sessionId': session_id,
                'english_text': '(Translation timed out)',
                'spanish_text': '(Traducción agotada por tiempo)',
                'audio': original_audio_b64,
                'is_original_audio': True,
                'backup_timeout': True
            })
        except Exception as e:
            logging.error(f"Error in backup timeout handler: {e}")
    
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
            
            logging.info(f"Saved WebRTC audio to {temp_file_path} ({len(audio_bytes)} bytes)")
        
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
                    logging.info(f"Transcribed with Google: {text}")
                    return text.strip()
            except Exception as e:
                logging.warning(f"Transcription error: {e}")
                return "Hello, this is a test message."  # Default fallback text
        
        # translation function to be executed with a timeout
        def process_and_translate():
            try:
                # Process audio - transcribe using the simplified function
                english_text = safe_transcribe(temp_file_path)
                logging.info(f"Using text for translation: {english_text}")
                
                # Get the translation
                translator = TranslationModel()
                spanish_text = translator.translate(english_text)
                logging.info(f"Translated to: {spanish_text}")
                
                # Generate simple audio 
                tts_audio = generate_tts(spanish_text)
                tts_audio_b64 = base64.b64encode(tts_audio).decode('utf-8')
                
                return {
                    'success': True,
                    'english_text': english_text,
                    'spanish_text': spanish_text,
                    'audio': tts_audio_b64
                }
            except Exception as e:
                logging.error(f"Error in process_and_translate: {e}")
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
                        # Send back results
                        emit('webrtc_translation', {
                            'sessionId': session_id,
                            'english_text': result['english_text'],
                            'spanish_text': result['spanish_text'],
                            'audio': result['audio']
                        })
                        result_sent = True
                        # Log success for debugging
                        logging.info(f"Successfully sent translation back to client: '{result['spanish_text']}'")
                    else:
                        # Handle translation failure - still return original audio
                        logging.warning(f"Translation process failed: {result.get('error', 'Unknown error')}")
                        emit('webrtc_translation', {
                            'sessionId': session_id,
                            'english_text': '(Translation failed)',
                            'spanish_text': '(Error de traducción)',
                            'audio': original_audio_b64,
                            'is_original_audio': True
                        })
                        result_sent = True
                except concurrent.futures.TimeoutError:
                    # Inner timeout - handle separately to ensure we get here
                    logging.warning(f"Inner timeout occurred in future.result")
                    # This will be handled by the outer exception handler
                    raise
        except concurrent.futures.TimeoutError:
            # Timeout occurred - send back the original audio
            if not result_sent:
                logging.warning(f"Translation timed out after 15 seconds, returning original audio")
                emit('webrtc_translation', {
                    'sessionId': session_id,
                    'english_text': '(Translation timed out)',
                    'spanish_text': '(Traducción agotada por tiempo)',
                    'audio': original_audio_b64,
                    'is_original_audio': True
                })
                result_sent = True
        except Exception as e:
            # Generic error in the executor - send back the original audio
            if not result_sent:
                logging.error(f"Error in translation executor: {e}")
                emit('webrtc_translation', {
                    'sessionId': session_id,
                    'english_text': '(Translation error)',
                    'spanish_text': '(Error de traducción)',
                    'audio': original_audio_b64,
                    'is_original_audio': True
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
        logging.error(f"Error processing WebRTC audio: {e}")
        # Make sure we send a response even in case of error
        if not result_sent:
            emit('webrtc_translation', {
                'sessionId': session_id,
                'english_text': '(Processing error)',
                'spanish_text': '(Error de procesamiento)',
                'audio': original_audio_b64,
                'is_original_audio': True
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
            self.model = None
            return
            
        logging.info("GEMINI_API_KEY found. Full functionality available.")
        genai.configure(api_key=api_key)
        
        # Use gemini-1.5-pro by default, or fall back to gemini-pro
        model_name = "gemini-1.5-pro"
        logging.info(f"Initialized Gemini with model: {model_name}")
        
        # Create the model instance
        self.model = genai.GenerativeModel(
            model_name=model_name,
            generation_config={"temperature": 0.0, "max_output_tokens": 1024}
        )

    def conversation(self, text):
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
            
            response = self.model.generate_content(prompt)
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

# ----------------- WebSocket Handlers -----------------

@socketio.on('connect')
def handle_connect():
    logging.info("Client connected")
    emit('connected', {'data': 'Connected to server'})

@socketio.on('translate')
def handle_translate(data):
    text = data.get('text', '')
    session_id = data.get('sessionId', '')
    if not text:
        emit('translation_final', {'sessionId': session_id, 'data': "No message received"})
        return
    translation = gemini_instance.conversation(text)
    emit('translation_final', {'sessionId': session_id, 'data': translation})

@socketio.on('audio_stream')
def handle_audio_stream(data):
    sessionId = data.get('sessionId', 'unknown')
    audio_b64 = data.get('data', '')
    try:
        audio_bytes = base64.b64decode(audio_b64)
        chunk_length = len(audio_bytes)
        logging.info("Received audio stream chunk from session %s, data length: %d bytes", sessionId, chunk_length)
    except Exception as e:
        logging.error("Error decoding audio data for session %s: %s", sessionId, e)
        return
    emit('audio_ack', {'sessionId': sessionId, 'message': f'Audio chunk received, length: {chunk_length} bytes'})

@app.route('/', methods=['GET'])
def index():
    return '<h2>Server is running! Use /echo, /upload, /test_translation, or connect via WebSocket.</h2>'

if __name__ == '__main__':
    logging.info(f"Starting server on port {PORT}")
    try:
        socketio.run(app, host='127.0.0.1', port=PORT, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        logging.info("Server stopped by user")
    except Exception as e:
        logging.error(f"Server error: {e}", exc_info=True)
