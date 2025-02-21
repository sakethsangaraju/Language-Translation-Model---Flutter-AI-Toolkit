import eventlet
eventlet.monkey_patch()  # Must be at the very top!

import os
import time
import random
import logging
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO, emit

# Configure logging: set to INFO overall but reduce the verbosity for these specific modules.
logging.basicConfig(level=logging.INFO)
logging.getLogger('engineio').setLevel(logging.WARNING)
logging.getLogger('socketio').setLevel(logging.WARNING)
logging.getLogger('werkzeug').setLevel(logging.WARNING)

app = Flask(__name__)
CORS(app)

# Initialize SocketIO for WebSocket support with reduced internal logging.
socketio = SocketIO(app, cors_allowed_origins="*", logger=False, engineio_logger=False)

PORT = 8008
UPLOAD_FOLDER = 'uploads'
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

# --- REST Endpoints ---

@app.route('/echo', methods=['POST'])
def echo():
    data = request.get_json()
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    text = data['text']
    app.logger.info("Received text: %s", text)
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

    # Create a unique filename using a timestamp.
    _, ext = os.path.splitext(file.filename)
    filename = f"{int(time.time() * 1000)}{ext}"
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
    file.save(file_path)
    app.logger.info("Image uploaded: %s", filename)
    image_url = f"http://localhost:{PORT}/uploads/{filename}"
    return jsonify({
        'url': image_url,
        'message': f'File "{filename}" uploaded successfully!'
    })

@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

# --- WebSocket & Gemini API Mock Integration ---

def mock_gemini_translate(text):
    """
    Simulates a translation process by gradually building up the translated text.
    For a multi-word sentence, you'll see multiple partial updates before the final result.
    """
    words = text.split()
    partials = []
    current = ""
    for word in words:
        current += " " + word
        time.sleep(random.uniform(0.1, 0.5))  # Simulate processing delay
        partials.append(current.strip())
    return partials

@socketio.on('translate')
def handle_translate(data):
    text = data.get('text', '')
    sessionId = data.get('sessionId', 'unknown')
    app.logger.info("WebSocket: Received translation request for session %s: %s", sessionId, text)
    partials = mock_gemini_translate(text)
    # Send partial updates for real-time feedback.
    for partial in partials:
        emit('translation_update', {
            'sessionId': sessionId,
            'data': partial,
            'partial': True,
            'timestamp': time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        })
    # Finally, send the complete translation.
    emit('translation_final', {
        'sessionId': sessionId,
        'data': partials[-1] if partials else "",
        'partial': False,
        'timestamp': time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    })

@app.route('/', methods=['GET'])
def index():
    return '<h2>Server is running! Use /echo, /upload, or connect via WebSocket.</h2>'

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=PORT, debug=False, use_reloader=False)
