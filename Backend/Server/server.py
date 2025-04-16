import asyncio
import json
import os
import websockets
from google import genai
import base64
import io
from pydub import AudioSegment
import google.generativeai as generative
import wave
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Initialize global counter for audio chunks
user_chunk_counter = 0

# Get API key from environment
api_key = os.getenv('GOOGLE_API_KEY')
if not api_key:
    raise ValueError("GOOGLE_API_KEY environment variable is not set")

os.environ['GOOGLE_API_KEY'] = api_key
generative.configure(api_key=api_key)
MODEL = "gemini-2.0-flash-exp"   # Latest stable Flash model for general use
TRANSCRIPTION_MODEL = "gemini-1.5-flash-8b"  # Same model for transcription
client = genai.Client(
  http_options={
    'api_version': 'v1alpha',
  }
)

# Function to save PCM data as MP3
def save_pcm_as_mp3(pcm_data, sample_rate=16000, filename="output.mp3"):
    """Saves PCM audio data as an MP3 file."""
    try:
        # Create a WAV in memory
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(pcm_data)
        
        # Reset buffer position
        wav_buffer.seek(0)
        
        # Convert WAV to MP3
        audio_segment = AudioSegment.from_wav(wav_buffer)
        
        # Ensure directory exists
        os.makedirs("audio_clips", exist_ok=True)
        file_path = os.path.join("audio_clips", filename)
        
        # Export as MP3
        audio_segment.export(file_path, format="mp3", codec="libmp3lame")
        print(f"Saved audio clip to {file_path}")
        return True
        
    except Exception as e:
        print(f"Error saving PCM as MP3: {e}")
        return False

async def gemini_session_handler(client_websocket: websockets.WebSocketServerProtocol):
    """Handles the interaction with Gemini API within a websocket session."""
    try:
        config_message = await client_websocket.recv()
        config_data = json.loads(config_message)
        config = config_data.get("setup", {})
        
        # Ensure we have system instructions for translation
        if "system_instruction" not in config:
            config["system_instruction"] = {
                "parts": [{
                    "text": """You are NativeFlow, a friendly and helpful multilingual language assistant, live translator, and tutor. Listen carefully to the user's request spoken in their language.

1.  **Identify User's Goal:** Determine if the user wants to:
    * Translate a phrase from their language *into* another language (e.g., "How do I say 'thank you' in Vietnamese?").
    * Understand the meaning of a phrase spoken in a foreign language *in English* (e.g., User speaks Vietnamese: "Cảm ơn nghĩa là gì?").
    * Get help with pronunciation (e.g., "Can you say that again slowly?").

2.  **Translation (User Language -> Target Language):**
    * Identify the user's original language and the target language.
    * Identify the phrase to translate.
    * Respond naturally *in the user's original language* for conversational text.
    * Provide the translation *text* accurately in the target language.
    * **IMPORTANT AUDIO:** Generate the spoken translation audio **using a clear, native-sounding accent for the *target language*** (e.g., use a Vietnamese accent for Vietnamese audio, a Mandarin Chinese accent for Mandarin audio, etc.). Avoid using a generic or American English accent for non-English translations.
    * Offer brief context or pronunciation guidance if helpful.

3.  **Translation (Foreign Language -> English):**
    * Identify the foreign language phrase spoken by the user.
    * Recognize the request is for the English meaning.
    * Respond *in English*, providing the clear English translation (text and audio). The audio for the *English* translation can use a standard English accent.

4.  **Pronunciation Assistance:**
    * If the user asks you to repeat a translation slowly (e.g., "Say that again slowly," "Can you repeat that?", "Slow down"), repeat *only* the translated phrase from the previous turn.
    * Speak the repeated phrase clearly and at a noticeably slower pace, enunciating carefully **using the same native-sounding accent of the target language** as the original translation. Avoid adding extra conversational text during the slow repetition.

Your primary goal is to be a seamless live translation and language learning assistant, responding accurately and helpfully with clear text and **appropriately accented, natural-sounding spoken audio** (including slowed-down audio for pronunciation)."""
                }]
            }
        
        # Add language preference to the configuration
        if "generation_config" not in config:
            config["generation_config"] = {}
        
        # Set English as the default language
        config["generation_config"]["language"] = "en"
         
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("Connected to Gemini API")

            async def send_to_gemini():
                global user_chunk_counter
                """Sends messages (audio or text) from the client websocket to the Gemini API."""
                try:
                  async for message in client_websocket:
                      try:
                          data = json.loads(message)

                          if "text_input" in data and "text" in data["text_input"]:
                              user_text = data["text_input"]["text"]
                              print(f"Received text input from client: {user_text}")
                              await session.send({"text": user_text})
                              print(f"Sent text to Gemini: {user_text}")
                              user_chunk_counter = 0

                          elif "realtime_input" in data:
                              for chunk in data["realtime_input"]["media_chunks"]:
                                  if chunk["mime_type"] == "audio/pcm":
                                      user_chunk_counter += 1
                                      chunk_filename = f"user_input_chunk_{user_chunk_counter}.mp3"
                                      decoded_data = base64.b64decode(chunk["data"]) # Decode once
                                      save_pcm_as_mp3(
                                          decoded_data,
                                          16000,
                                          filename=chunk_filename
                                      )
                                      await session.send({"mime_type": "audio/pcm", "data": decoded_data})

                                  elif chunk["mime_type"] == "image/jpeg":
                                       decoded_data = base64.b64decode(chunk["data"]) # Decode once
                                       await session.send({"mime_type": "image/jpeg", "data": decoded_data})

                      except json.JSONDecodeError:
                           print(f"Received non-JSON message: {message}")
                      except Exception as e:
                          print(f"Error processing client message: {e}")

                  print("Client connection closed (send)")
                except websockets.exceptions.ConnectionClosedOK:
                     print("Client connection closed normally (send loop)")
                except Exception as e:
                     # Print the specific error during send
                     print(f"Error sending to Gemini: {e}") # This will now show the original error if it persists
                finally:
                   print("send_to_gemini task finished")



            async def receive_from_gemini():
                """Receives responses from the Gemini API and forwards them to the client, looping until turn is complete."""
                try:
                    # Initialize audio_data attribute on session
                    session.audio_data = b''
                    
                    while True:
                        try:
                            print("receiving from gemini")
                            async for response in session.receive():
                                if response.server_content is None:
                                    print(f'Unhandled server message! - {response}')
                                    continue

                                model_turn = response.server_content.model_turn
                                if model_turn:
                                    for part in model_turn.parts:
                                        if hasattr(part, 'text') and part.text is not None:
                                            await client_websocket.send(json.dumps({"text": part.text}))
                                        elif hasattr(part, 'inline_data') and part.inline_data is not None:
                                            print("audio mime_type:", part.inline_data.mime_type)
                                            base64_audio = base64.b64encode(part.inline_data.data).decode('utf-8')
                                            
                                            await client_websocket.send(json.dumps({"audio": base64_audio}))
                                            
                                            # Accumulate the audio data here
                                            session.audio_data += part.inline_data.data
                                            
                                            print("audio received")

                                if response.server_content.turn_complete:
                                    print('\n<Turn complete>')
                                    # Transcribe the accumulated audio here
                                    if hasattr(session, 'audio_data') and session.audio_data:
                                        transcribed_text = transcribe_audio(session.audio_data)
                                        if transcribed_text:    
                                            await client_websocket.send(json.dumps({
                                                "text": transcribed_text
                                            }))
                                        # Clear the accumulated audio data
                                        session.audio_data = b''
                        except websockets.exceptions.ConnectionClosedOK:
                            print("Client connection closed normally (receive)")
                            break  # Exit the loop if the connection is closed
                        except Exception as e:
                            print(f"Error receiving from Gemini: {e}")
                            break 

                except Exception as e:
                      print(f"Error receiving from Gemini: {e}")
                finally:
                      print("Gemini connection closed (receive)")


            # Start send loop
            send_task = asyncio.create_task(send_to_gemini())
            # Launch receive loop as a background task
            receive_task = asyncio.create_task(receive_from_gemini())
            await asyncio.gather(send_task, receive_task)


    except Exception as e:
        print(f"Error in Gemini session: {e}")
    finally:
        print("Gemini session closed.")

def transcribe_audio(audio_data):
    """Transcribes audio using Gemini 1.5 Flash."""
    try:
        # Make sure we have valid audio data
        if not audio_data:
            return "No audio data received."
            
        # Convert PCM to MP3
        mp3_audio_base64 = convert_pcm_to_mp3(audio_data)
        if not mp3_audio_base64:
            return "Audio conversion failed."
            
        # Create a client specific for transcription (assuming Gemini 1.5 flash)
        transcription_client = generative.GenerativeModel(model_name=TRANSCRIPTION_MODEL)
        
        prompt = """Generate a transcript of the speech. 
        Please do not include any other text in the response. 
        If you cannot hear the speech, please only say '<Not recognizable>'."""
        
        response = transcription_client.generate_content(
            [
                prompt,
                {
                    "mime_type": "audio/mp3", 
                    "data": base64.b64decode(mp3_audio_base64),
                }
            ]
        )
            
        return response.text

    except Exception as e:
        print(f"Transcription error: {e}")
        return "Transcription failed.", None

def convert_pcm_to_mp3(pcm_data):
    """Converts PCM audio to base64 encoded MP3."""
    try:
        # Create a WAV in memory first
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(24000)  # 24kHz
            wav_file.writeframes(pcm_data)
        
        # Reset buffer position
        wav_buffer.seek(0)
        
        # Convert WAV to MP3
        audio_segment = AudioSegment.from_wav(wav_buffer)
        
        # Export as MP3
        mp3_buffer = io.BytesIO()
        audio_segment.export(mp3_buffer, format="mp3", codec="libmp3lame")
        
        # Convert to base64
        mp3_base64 = base64.b64encode(mp3_buffer.getvalue()).decode('utf-8')
        return mp3_base64
        
    except Exception as e:
        print(f"Error converting PCM to MP3: {e}")
        return None


async def main() -> None:
    async with websockets.serve(gemini_session_handler, "localhost", 9083):
        print("Running websocket server localhost:9083...")
        await asyncio.Future()  # Keep the server running indefinitely


if __name__ == "__main__":
    asyncio.run(main())