import asyncio
import websockets

async def hello(websocket):
    msg = await websocket.recv()
    echo = f"Message sent: {msg}"
    print(echo)

    await websocket.send(echo)

async def main():
    async with websockets.serve(hello, "localhost", 8765):
        #run forever
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
import eventlet
eventlet.monkey_patch()  # Must be at the very top!

import base64  # For audio encoding/decoding
import os
import time
import random
import logging
import re
import json

from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO, emit


import google.generativeai as genai

# Set up logging
logging.basicConfig(level=logging.INFO)
logging.getLogger('engineio').setLevel(logging.WARNING)
logging.getLogger('socketio').setLevel(logging.WARNING)
logging.getLogger('werkzeug').setLevel(logging.WARNING)

app = Flask(__name__)
CORS(app, resources={r"/uploads/*": {"origins": "*"}})
socketio = SocketIO(app, cors_allowed_origins="*", logger=False, engineio_logger=False)

# Server configuration
PORT = 8008
UPLOAD_FOLDER = os.path.abspath('uploads')  # Use an absolute path
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)
# API key in environment variable
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    raise ValueError("GEMINI_API_KEY environment variable not set")
genai.configure(api_key=GEMINI_API_KEY)

# ----------------- REST Endpoints -----------------

@app.route('/echo', methods=['POST'])
def echo():
    # Receive JSON with a 'text' key, log it, and return an echo message.
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
    # Handle image upload; save with a timestamped filename and return the URL.
    if 'file' not in request.files:
        return jsonify({'error': 'No file uploaded'}), 400
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400

    _, ext = os.path.splitext(file.filename)
    filename = f"{int(time.time() * 1000)}{ext}"
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
    file.save(file_path)
    logging.info("Image uploaded: %s", filename)
    image_url = f"http://127.0.0.1{PORT}/uploads/{filename}"
    return jsonify({
        'url': image_url,
        'message': f'File "{filename}" uploaded successfully!'
    })

@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    # Serve uploaded files.
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

@app.route('/test_translation', methods=['POST'])
def test_translation():
    # Test endpoint for Gemini translation (without WebSockets).
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
    # Handles translation via the Gemini API.
    def __init__(self, model='gemini-2.0-flash'):
        self.model = model
        self.connection = True

    def test_connection(self):
        return self.connection

    def disconnect(self):
        self.connection = False

    def conversation(self, message):
        # Translate English text to Spanish using a structured JSON prompt.
        if not self.connection:
            raise ConnectionError("Server disconnected")
        if not message:
            return "No message received"
        self.latency_simulation()
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
            model_instance = genai.GenerativeModel(
                model_name=self.model,
                generation_config={
                    "temperature": 0.0,
                    "top_p": 1.0,
                    "top_k": 1,
                    "max_output_tokens": 1024,
                },
            )
            response = model_instance.generate_content(prompt)
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

    def latency_simulation(self, a=False):
        # Simulate latency for demonstration purposes.
        if a:
            time.sleep(5)
        else:
            time.sleep(random.uniform(0.05, 2))

gemini_instance = Gemini(model='gemini-2.0-flash')

# ----------------- WebSocket Handlers -----------------

@socketio.on('translate')
def handle_translate(data):
    # Handle translation requests via WebSocket.
    text = data.get('text', '')
    session_id = data.get('sessionId', '')
    if not text:
        emit('translation_final', {'sessionId': session_id, 'data': "No message received"})
        return
    translation = gemini_instance.conversation(text)
    emit('translation_final', {'sessionId': session_id, 'data': translation})

@socketio.on('audio_stream')
def handle_audio_stream(data):
    # Handle incoming audio streams (Base64 encoded) and send an acknowledgment.
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
    # Basic index endpoint.
    return '<h2>Server is running! Use /echo, /upload, /test_translation, or connect via WebSocket.</h2>'

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=PORT, debug=False, use_reloader=False)
