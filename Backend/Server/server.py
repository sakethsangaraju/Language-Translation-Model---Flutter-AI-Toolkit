import eventlet
eventlet.monkey_patch()  # Must be at the very top!
from dotenv import load_dotenv
load_dotenv
import base64
import os
import random
import time 
import logging
import re
import json

from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO, emit
from werkzeug.utils import secure_filename  # New: for safe filenames

from google import genai
from google.genai import types

# Set up logging
logging.basicConfig(level=logging.INFO)
logging.getLogger('engineio').setLevel(logging.WARNING)
logging.getLogger('socketio').setLevel(logging.WARNING)
logging.getLogger('werkzeug').setLevel(logging.WARNING)

app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", logger=False, engineio_logger=False, async_mode='eventlet')

# Server configuration
PORT = 8008
# Use an absolute path for UPLOAD_FOLDER
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(BASE_DIR, 'uploads')
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

# API key in environment variable
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    raise ValueError("GEMINI_API_KEY environment variable not set")
client = genai.Client(api_key=GEMINI_API_KEY)

# ----------------- REST Endpoints -----------------

@app.route('/echo', methods=['POST'])
def echo():
    data = request.get_json()
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    text = data['text']
    logging.info("Received text: %s", text)
    return jsonify({
        'echo': text,
        'message': 'Server received your text successfully!'
    })

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return jsonify({'error': 'No file uploaded'}), 400
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400

    # Secure the filename and append a timestamp for uniqueness
    original_filename = secure_filename(file.filename)
    name, ext = os.path.splitext(original_filename)
    timestamp = int(random.random() * 1000 + time.time() * 1000)
    filename = f"{name}_{timestamp}{ext}"
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
    file.save(file_path)
    logging.info("Image uploaded: %s", filename)
    # Use request.host_url for a dynamic URL (e.g., if running on a device)
    image_url = f"{request.host_url}uploads/{filename}"
    return jsonify({
        'url': image_url,
        'message': f'File "{filename}" uploaded successfully!'
    })

@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

@app.route('/test_translation', methods=['POST'])
def test_translation():
    data = request.get_json()
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    text = data['text']
    logging.info("Test translation request: %s", text)
    try:
        translation = gemini_instance.conversation(text)
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

    def test_connection(self):
        return self.connection

    def disconnect(self):
        self.connection = False

    def conversation(self, message):
        if not self.connection:
            raise ConnectionError("Server disconnected")
        if not message:
            return "No message received"
        prompt = f"""
You are a translator from English to Spanish.
Respond only in valid JSON with exactly one key: "translation".
No extra text, no code blocks, no commentary.
For example:
{{"translation": "Hola"}}
Now, translate this text:
"{message}"
        """
        try:
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
            try:
                parsed = json.loads(raw_output)
                translation = parsed.get("translation", "").strip()
                if not translation:
                    logging.warning("JSON parsed but 'translation' was empty.")
                    return "Translation error."
                logging.info("Parsed translation: %s", translation)
                return translation
            except json.JSONDecodeError:
                logging.warning("Model did not produce valid JSON. Attempting fallback cleanup.")
                fallback = re.sub(r'(\"?translation\"?:?\s*)', '', raw_output, flags=re.IGNORECASE)
                fallback = fallback.strip('"\' \n:')
                return fallback if fallback else "Translation error."
        except Exception as e:
            logging.error("Error during Gemini translation: %s", e)
            return "Translation error."

gemini_instance = Gemini(model='gemini-2.0-flash')

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
    socketio.run(app, host='0.0.0.0', port=PORT, debug=False, use_reloader=False)