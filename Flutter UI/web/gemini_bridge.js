// web/gemini_bridge.js

// --- Configuration ---
let WEBSOCKET_URL = "ws://localhost:9083";
const FALLBACK_WEBSOCKET_URLS = [
    "ws://localhost:9083", 
    "ws://127.0.0.1:9083",
    "ws://" + window.location.hostname + ":9083",
    "wss://" + window.location.hostname + ":9083"
];
let wsUrlIndex = 0;

const IMAGE_CAPTURE_INTERVAL_MS = 3000;
const AUDIO_CHUNK_INTERVAL_MS = 3000;
const AUDIO_INPUT_SAMPLE_RATE = 16000;
const AUDIO_OUTPUT_SAMPLE_RATE = 24000;

// --- State ---
let videoElement = null;
let canvasElement = null;
let videoStream = null;
let currentFrameB64 = null;
let webSocket = null;
let audioInputContext = null;
let audioInputProcessor = null;
let pcmData = [];
let audioInputInterval = null;
let isRecording = false;
let audioOutputContext = null;
let audioOutputWorkletNode = null;
let isAudioOutputInitialized = false;
let connectionAttempts = 0;
const MAX_CONNECTION_ATTEMPTS = 3;

// --- Callbacks (to be set by Dart) ---
let onWebSocketOpen = null;
let onWebSocketMessage = null;
let onWebSocketClose = null;
let onWebSocketError = null;
let onAudioChunkReady = null;
let onFrameReady = null;
let onRecordingStateChange = null;

// --- Functions Exposed to Dart ---

function initializeBridge(callbacks) {
    console.log("JS Bridge: Initializing...");
    onWebSocketOpen = callbacks.onWebSocketOpen;
    onWebSocketMessage = callbacks.onWebSocketMessage;
    onWebSocketClose = callbacks.onWebSocketClose;
    onWebSocketError = callbacks.onWebSocketError;
    onAudioChunkReady = callbacks.onAudioChunkReady;
    onFrameReady = callbacks.onFrameReady;
    onRecordingStateChange = callbacks.onRecordingStateChange;

    // Get references to elements created by Dart
    videoElement = document.getElementById('videoElement');
    canvasElement = document.getElementById('canvasElement');
    
    if (!videoElement || !canvasElement) {
        console.error("JS Bridge: Required elements not found!");
        return false;
    }

    console.log("JS Bridge: Elements found and initialized.");
    return true;
}

function connectWebSocket() {
    if (webSocket && webSocket.readyState === WebSocket.OPEN) {
        console.log("JS Bridge: WebSocket already open.");
        return;
    }
    
    if (connectionAttempts >= MAX_CONNECTION_ATTEMPTS) {
        console.error(`JS Bridge: Max connection attempts (${MAX_CONNECTION_ATTEMPTS}) reached. Giving up.`);
        if (onWebSocketError) onWebSocketError("Maximum connection attempts reached. Server may be offline.");
        return;
    }
    
    // Try the next URL in the array
    WEBSOCKET_URL = FALLBACK_WEBSOCKET_URLS[wsUrlIndex % FALLBACK_WEBSOCKET_URLS.length];
    wsUrlIndex++;
    connectionAttempts++;
    
    console.log(`JS Bridge: Connection attempt ${connectionAttempts}/${MAX_CONNECTION_ATTEMPTS} to ${WEBSOCKET_URL}`);
    
    try {
        webSocket = new WebSocket(WEBSOCKET_URL);
        
        // Set a connection timeout
        const connectionTimeout = setTimeout(() => {
            if (webSocket && webSocket.readyState !== WebSocket.OPEN) {
                console.error("JS Bridge: WebSocket connection timed out.");
                webSocket.close();
                // Try next URL
                connectWebSocket();
            }
        }, 5000); // 5 second timeout
        
        webSocket.onopen = (event) => {
            clearTimeout(connectionTimeout);
            connectionAttempts = 0; // Reset counter on successful connection
            console.log("JS Bridge: WebSocket opened.", event);
            if (onWebSocketOpen) onWebSocketOpen();
            // Send initial setup immediately after opening
            sendInitialSetupMessage();
        };

        webSocket.onmessage = (event) => {
            // console.log("JS Bridge: WebSocket message received.", event.data);
            if (onWebSocketMessage) onWebSocketMessage(event.data); // Pass raw data string
        };

        webSocket.onclose = (event) => {
            console.log("JS Bridge: WebSocket closed.", event);
            webSocket = null;
            if (onWebSocketClose) onWebSocketClose(event.code, event.reason);
        };

        webSocket.onerror = (event) => {
            console.error("JS Bridge: WebSocket error.", event);
            if (onWebSocketError) onWebSocketError("WebSocket error occurred."); // Pass generic error
        };
    } catch (e) {
        console.error("JS Bridge: Error creating WebSocket:", e);
        if (onWebSocketError) onWebSocketError("Error creating WebSocket: " + e.message);
        
        // Try the next URL after a short delay
        setTimeout(connectWebSocket, 1000);
    }
}

function sendWebSocketMessage(message) {
    if (!webSocket || webSocket.readyState !== WebSocket.OPEN) {
        console.error("JS Bridge: WebSocket not open. Cannot send message.");
        return;
    }
    // console.log("JS Bridge: Sending WebSocket message:", message);
    webSocket.send(message); // Expects a string (usually JSON)
}

function sendInitialSetupMessage() {
    console.log("JS Bridge: Sending setup message");
    const setup_client_message = {
        setup: {
            generation_config: {
                response_modalities: ["AUDIO"]
            },
            system_instruction: {
                parts: [{
                    text: "You are a helpful bilingual assistant that translates between English and Spanish. " +
                          "When you receive input in English, respond in Spanish. " +
                          "When you receive input in Spanish, respond in English. " +
                          "Always include the translation of what was said in your response."
                }]
            }
        },
    };
    sendWebSocketMessage(JSON.stringify(setup_client_message));
}


async function startMediaStream(useCamera = false) {
    console.log(`JS Bridge: Starting media stream (Camera: ${useCamera})`);
    stopMediaStream(); // Stop any existing stream first

    // Ensure video element exists
    if (!videoElement) {
        console.log("JS Bridge: Video element not found, creating it");
        videoElement = document.getElementById('videoElement');
        
        if (!videoElement) {
            console.log("JS Bridge: Creating video element dynamically");
            videoElement = document.createElement('video');
            videoElement.id = 'videoElement';
            videoElement.autoplay = true;
            videoElement.muted = true;
            videoElement.setAttribute('playsinline', ''); // For iOS
            videoElement.style.width = '100%';
            videoElement.style.height = '100%';
            videoElement.style.objectFit = 'contain';
            videoElement.style.backgroundColor = 'black';
            const container = document.getElementById('video-container');
            if (container) {
                container.appendChild(videoElement);
            } else {
                document.body.appendChild(videoElement);
            }
        }
    }

    // Show a loading message in the video element
    if (videoElement) {
        const loadingDiv = document.createElement('div');
        loadingDiv.id = 'video-loading-indicator';
        loadingDiv.style.position = 'absolute';
        loadingDiv.style.top = '0';
        loadingDiv.style.left = '0';
        loadingDiv.style.width = '100%';
        loadingDiv.style.height = '100%';
        loadingDiv.style.display = 'flex';
        loadingDiv.style.justifyContent = 'center';
        loadingDiv.style.alignItems = 'center';
        loadingDiv.style.backgroundColor = 'rgba(0,0,0,0.8)';
        loadingDiv.style.color = 'white';
        loadingDiv.style.zIndex = '10';
        loadingDiv.style.fontSize = '16px';
        loadingDiv.innerText = 'Requesting media permissions...';
        videoElement.parentNode?.appendChild(loadingDiv);
        
        // Remove the loading message after 10 seconds if still there
        setTimeout(() => {
            const loadingElement = document.getElementById('video-loading-indicator');
            if (loadingElement) {
                loadingElement.remove();
            }
        }, 10000);
    }

    try {
        let stream = null;
        
        if (useCamera) {
            try {
                // Camera access
                console.log("JS Bridge: Requesting camera access...");
                stream = await navigator.mediaDevices.getUserMedia({
                    video: { width: { ideal: 640 }, height: { ideal: 480 } },
                    audio: false // Audio input is handled separately
                });
                console.log("JS Bridge: Camera access granted.");
            } catch (err) {
                console.error("JS Bridge: Error accessing camera:", err);
                // Try a simpler constraint set if the first request fails
                try {
                    stream = await navigator.mediaDevices.getUserMedia({
                        video: true,
                        audio: false
                    });
                    console.log("JS Bridge: Camera access granted with basic constraints.");
                } catch (fallbackErr) {
                    console.error("JS Bridge: Camera access denied even with basic constraints:", fallbackErr);
                    throw fallbackErr; // Re-throw to be caught by outer try/catch
                }
            }
        } else {
            // Screen sharing
            try {
                console.log("JS Bridge: Requesting screen sharing...");
                stream = await navigator.mediaDevices.getDisplayMedia({
                    video: { width: { max: 1280 }, height: { max: 720 } },
                    audio: false
                });
                console.log("JS Bridge: Screen sharing granted.");
            } catch (err) {
                console.error("JS Bridge: Error starting screen sharing:", err);
                
                // Show a message about the error
                if (videoElement) {
                    const errorDiv = document.createElement('div');
                    errorDiv.style.position = 'absolute';
                    errorDiv.style.top = '0';
                    errorDiv.style.left = '0';
                    errorDiv.style.width = '100%';
                    errorDiv.style.height = '100%';
                    errorDiv.style.display = 'flex';
                    errorDiv.style.flexDirection = 'column';
                    errorDiv.style.justifyContent = 'center';
                    errorDiv.style.alignItems = 'center';
                    errorDiv.style.backgroundColor = 'rgba(0,0,0,0.8)';
                    errorDiv.style.color = 'white';
                    errorDiv.style.zIndex = '10';
                    errorDiv.style.padding = '20px';
                    errorDiv.style.textAlign = 'center';
                    
                    errorDiv.innerHTML = `
                        <div style="font-size:18px;color:red;margin-bottom:10px;">Screen sharing permission denied</div>
                        <div>The app needs screen sharing to function properly.</div>
                        <button style="margin-top:20px;padding:8px 16px;background:#3498db;color:white;border:none;border-radius:4px;cursor:pointer;" 
                                onclick="requestScreenAgain()">
                            Try Again
                        </button>
                    `;
                    videoElement.parentNode?.appendChild(errorDiv);
                    
                    // Add global function to try again
                    window.requestScreenAgain = async function() {
                        errorDiv.remove();
                        try {
                            await startMediaStream(false);
                        } catch (e) {
                            console.error("Retry failed:", e);
                        }
                    };
                }
                
                // Try camera as fallback if screen sharing is denied
                try {
                    console.log("JS Bridge: Attempting to use camera as fallback...");
                    stream = await navigator.mediaDevices.getUserMedia({
                        video: true,
                        audio: false
                    });
                    console.log("JS Bridge: Camera fallback granted.");
                } catch (fallbackErr) {
                    console.error("JS Bridge: Both screen sharing and camera fallback failed:", fallbackErr);
                    throw err; // Throw original error
                }
            }
        }

        if (!stream) {
            throw new Error("Failed to get media stream");
        }

        videoStream = stream;
        
        // Remove any loading message
        const loadingElement = document.getElementById('video-loading-indicator');
        if (loadingElement) {
            loadingElement.remove();
        }

        if (videoElement) {
            // For Edge browser, sometimes setting srcObject directly doesn't work
            // We'll try using a more compatible approach
            try {
                videoElement.srcObject = videoStream;
            } catch (e) {
                console.warn("JS Bridge: Error setting srcObject, trying URL.createObjectURL", e);
                try {
                    // Fallback for older browsers
                    videoElement.src = URL.createObjectURL(videoStream);
                } catch (urlError) {
                    console.error("JS Bridge: Both methods of setting video source failed", urlError);
                }
            }
            
            videoElement.style.backgroundColor = 'black';
            
            // Make sure autoplay and muted are set
            videoElement.autoplay = true;
            videoElement.muted = true;
            videoElement.setAttribute('playsinline', ''); // For iOS
            
            // Force play in case autoplay doesn't work
            try {
                const playPromise = videoElement.play();
                if (playPromise !== undefined) {
                    playPromise.then(() => {
                        console.log("JS Bridge: Video playback started successfully.");
                    }).catch(err => {
                        console.warn("JS Bridge: Auto-play was prevented:", err);
                        // Show play button if autoplay is blocked
                        showPlayButton(videoElement);
                    });
                }
            } catch (playErr) {
                console.warn("JS Bridge: Video play() failed:", playErr);
                // Show play button if play() fails
                showPlayButton(videoElement);
            }
            
            // Wait for metadata and start capture
            videoElement.addEventListener('loadedmetadata', () => {
                console.log("JS Bridge: Video metadata loaded, starting frame capture");
                startFrameCapture();
            });
            
            console.log("JS Bridge: Video stream attached and ready.");
        } else {
            console.error("JS Bridge: videoElement not available to attach stream.");
            throw new Error("Video element not available");
        }
    } catch (err) {
        console.error("JS Bridge: Error accessing media devices.", err);
        stopMediaStream(); // Clean up if error occurs
        throw err; // Re-throw for Flutter to handle
    }
}

function stopMediaStream() {
    console.log("JS Bridge: Stopping media stream.");
    stopFrameCapture();
    if (videoStream) {
        videoStream.getTracks().forEach(track => track.stop());
        videoStream = null;
    }
    if (videoElement) {
        videoElement.srcObject = null;
    }
    currentFrameB64 = null; // Clear last captured frame
}

let frameCaptureInterval = null;
function startFrameCapture() {
    if (frameCaptureInterval) clearInterval(frameCaptureInterval); // Clear existing interval
    console.log("JS Bridge: Starting frame capture interval.");
    frameCaptureInterval = setInterval(captureAndSendFrame, IMAGE_CAPTURE_INTERVAL_MS);
    captureAndSendFrame(); // Capture immediately once
}

function stopFrameCapture() {
    console.log("JS Bridge: Stopping frame capture interval.");
    if (frameCaptureInterval) {
        clearInterval(frameCaptureInterval);
        frameCaptureInterval = null;
    }
}

function captureAndSendFrame() {
    if (!videoElement || !canvasElement || !videoStream || videoElement.readyState < videoElement.HAVE_METADATA || videoElement.videoWidth === 0) {
        // console.warn("JS Bridge: Video not ready for frame capture.");
        return;
    }
    try {
        const context = canvasElement.getContext('2d');
        canvasElement.width = videoElement.videoWidth;
        canvasElement.height = videoElement.videoHeight;
        context.drawImage(videoElement, 0, 0, canvasElement.width, canvasElement.height);
        const imageDataUrl = canvasElement.toDataURL('image/jpeg', 0.8); // Quality 0.8
        currentFrameB64 = imageDataUrl.split(',')[1].trim();

        // Optionally send frame immediately via callback if needed for other purposes
        if (onFrameReady) {
             // onFrameReady(currentFrameB64); // Decide if Dart needs every frame
        }
         // console.log("JS Bridge: Frame captured.");

    } catch (e) {
        console.error('JS Bridge: Error capturing frame:', e);
        currentFrameB64 = null; // Reset on error
    }
}

// --- Audio Input ---
async function startAudioInput() {
    if (isRecording) {
        console.warn("JS Bridge: Audio input already started.");
        return;
    }
    console.log("JS Bridge: Starting audio input...");

    try {
        // Ensure AudioContext is running (browsers suspend it sometimes)
        if (audioInputContext && audioInputContext.state === 'suspended') {
            await audioInputContext.resume();
        }

        if (!audioInputContext) {
             audioInputContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: AUDIO_INPUT_SAMPLE_RATE
             });
        }

        const stream = await navigator.mediaDevices.getUserMedia({
            audio: {
                channelCount: 1,
                sampleRate: AUDIO_INPUT_SAMPLE_RATE,
                echoCancellation: true // Enable echo cancellation
            }
        });

        const source = audioInputContext.createMediaStreamSource(stream);
        // Use ScriptProcessor for broader compatibility, buffer size 4096
        audioInputProcessor = audioInputContext.createScriptProcessor(4096, 1, 1);

        audioInputProcessor.onaudioprocess = (e) => {
            if (!isRecording) return; // Check if still recording

            const inputData = e.inputBuffer.getChannelData(0);
            // Convert Float32 to Int16 PCM
            const pcm16 = new Int16Array(inputData.length);
            for (let i = 0; i < inputData.length; i++) {
                pcm16[i] = Math.max(-32768, Math.min(32767, inputData[i] * 32767));
            }
            // Add to buffer - use spread syntax for efficiency
            pcmData.push(...pcm16);
        };

        source.connect(audioInputProcessor);
        audioInputProcessor.connect(audioInputContext.destination); // Connect to destination to keep processing active

        // Start interval to send chunks
        if (audioInputInterval) clearInterval(audioInputInterval);
        audioInputInterval = setInterval(sendAudioChunk, AUDIO_CHUNK_INTERVAL_MS);

        isRecording = true;
        if (onRecordingStateChange) onRecordingStateChange(true);
        console.log("JS Bridge: Audio input started successfully.");

    } catch (err) {
        console.error("JS Bridge: Error starting audio input.", err);
        stopAudioInput(); // Clean up on error
    }
}

function stopAudioInput() {
    if (!isRecording) return;
    console.log("JS Bridge: Stopping audio input...");
    isRecording = false; // Stop processing audio in onaudioprocess

    if (audioInputInterval) {
        clearInterval(audioInputInterval);
        audioInputInterval = null;
    }

    // Send any remaining data
    if (pcmData.length > 0) {
        sendAudioChunk();
    }

    if (audioInputProcessor) {
        audioInputProcessor.disconnect();
        audioInputProcessor = null;
    }
    // Don't close the context immediately, might be needed for playback
    // if (audioInputContext) {
    //     audioInputContext.close().then(() => audioInputContext = null);
    // }

    pcmData = []; // Clear buffer

    if (onRecordingStateChange) onRecordingStateChange(false);
    console.log("JS Bridge: Audio input stopped.");
}

function sendAudioChunk() {
    if (pcmData.length === 0 || !webSocket || webSocket.readyState !== WebSocket.OPEN) {
        return;
    }

    // Create Int16Array view, then get underlying ArrayBuffer
    const pcm16Array = new Int16Array(pcmData);
    const buffer = pcm16Array.buffer;

    // Convert ArrayBuffer to Base64
    const base64 = btoa(String.fromCharCode.apply(null, new Uint8Array(buffer)));
    pcmData = []; // Clear buffer after processing

    // Construct the message payload including the current frame
    const payload = {
        realtime_input: {
            media_chunks: [
                { mime_type: "audio/pcm", data: base64 }
            ]
        }
    };

    // Add image data if available
    if (currentFrameB64) {
        payload.realtime_input.media_chunks.push({
             mime_type: "image/jpeg", data: currentFrameB64
        });
    } else {
        console.warn("JS Bridge: No frame available to send with audio chunk.");
    }

    sendWebSocketMessage(JSON.stringify(payload));
     console.log("JS Bridge: Sent audio chunk and frame.");

    // Optional: Callback to Dart if needed (e.g., for UI feedback)
    if (onAudioChunkReady) {
        // onAudioChunkReady(base64); // Maybe not needed if sending directly
    }
}

// --- Audio Output ---
async function initializeAudioOutput() {
    if (isAudioOutputInitialized) return;
    console.log("JS Bridge: Initializing audio output...");
    try {
        audioOutputContext = new (window.AudioContext || window.webkitAudioContext)({
            sampleRate: AUDIO_OUTPUT_SAMPLE_RATE
        });
        // Ensure pcm-processor.js is in the web/ directory
        await audioOutputContext.audioWorklet.addModule('pcm-processor.js');
        audioOutputWorkletNode = new AudioWorkletNode(audioOutputContext, 'pcm-processor');
        audioOutputWorkletNode.connect(audioOutputContext.destination);
        isAudioOutputInitialized = true;
        console.log("JS Bridge: Audio output initialized successfully.");
    } catch (error) {
        console.error('JS Bridge: Error initializing audio output:', error);
        isAudioOutputInitialized = false;
    }
}

async function playAudioChunk(base64AudioChunk) {
    if (!isAudioOutputInitialized || !audioOutputContext || !audioOutputWorkletNode) {
        console.error("JS Bridge: Audio output not initialized. Cannot play chunk.");
        return;
    }

    try {
        // Ensure context is running
        if (audioOutputContext.state === 'suspended') {
            await audioOutputContext.resume();
        }

        const binaryString = window.atob(base64AudioChunk);
        const len = binaryString.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            bytes[i] = binaryString.charCodeAt(i);
        }
        // The ArrayBuffer contains Int16 PCM data (Little Endian assumed from server.py)
        const pcm16Array = new Int16Array(bytes.buffer);

        // Convert Int16 PCM to Float32 for AudioWorklet
        const float32Array = new Float32Array(pcm16Array.length);
        for (let i = 0; i < pcm16Array.length; i++) {
            float32Array[i] = pcm16Array[i] / 32768.0; // Normalize to [-1.0, 1.0]
        }

        // Send Float32 data to the worklet
        audioOutputWorkletNode.port.postMessage(float32Array);
        // console.log("JS Bridge: Sent audio chunk to worklet for playback.");

    } catch (error) {
        console.error('JS Bridge: Error processing or playing audio chunk:', error);
    }
}

// --- Helper to get WebSocket connection state ---
function isWebSocketConnected() {
    return webSocket !== null && webSocket.readyState === WebSocket.OPEN;
}

// Helper function to show a play button when autoplay is blocked
function showPlayButton(videoElement) {
    const playButtonContainer = document.createElement('div');
    playButtonContainer.id = 'play-button-container';
    playButtonContainer.style.position = 'absolute';
    playButtonContainer.style.top = '0';
    playButtonContainer.style.left = '0';
    playButtonContainer.style.width = '100%';
    playButtonContainer.style.height = '100%';
    playButtonContainer.style.display = 'flex';
    playButtonContainer.style.justifyContent = 'center';
    playButtonContainer.style.alignItems = 'center';
    playButtonContainer.style.backgroundColor = 'rgba(0,0,0,0.7)';
    playButtonContainer.style.cursor = 'pointer';
    playButtonContainer.style.zIndex = '100';
    
    const playButton = document.createElement('div');
    playButton.style.width = '80px';
    playButton.style.height = '80px';
    playButton.style.borderRadius = '50%';
    playButton.style.backgroundColor = '#3498db';
    playButton.style.display = 'flex';
    playButton.style.justifyContent = 'center';
    playButton.style.alignItems = 'center';
    
    // Play icon (triangle)
    const playIcon = document.createElement('div');
    playIcon.style.width = '0';
    playIcon.style.height = '0';
    playIcon.style.borderTop = '20px solid transparent';
    playIcon.style.borderBottom = '20px solid transparent';
    playIcon.style.borderLeft = '30px solid white';
    playIcon.style.marginLeft = '10px';
    
    playButton.appendChild(playIcon);
    playButtonContainer.appendChild(playButton);
    
    // Add to DOM
    videoElement.parentNode?.appendChild(playButtonContainer);
    
    // Add click handler
    playButtonContainer.addEventListener('click', function() {
        videoElement.play()
            .then(() => {
                playButtonContainer.remove();
                console.log("JS Bridge: Video playback started by user interaction.");
            })
            .catch(err => {
                console.error("JS Bridge: Play failed even after user interaction:", err);
            });
    });
}