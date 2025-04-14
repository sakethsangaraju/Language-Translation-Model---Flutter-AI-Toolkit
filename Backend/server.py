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

async def gemini_session_handler(client_websocket: websockets.WebSocketServerProtocol):
    """Handles the interaction with Gemini API within a websocket session."""
    try:
        config_message = await client_websocket.recv()
        config_data = json.loads(config_message)
        config = config_data.get("setup", {})

        # Ensure we have system instructions for translation (REPLACED BLOCK)
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
    * Respond naturally in the user's original language.
    * Clearly provide the translation (text and audio) in the target language.
    * Offer brief context or pronunciation guidance if helpful.

3.  **Translation (Foreign Language -> English):**
    * Identify the foreign language phrase spoken by the user.
    * Recognize the request is for the English meaning.
    * Respond *in English*, providing the clear English translation (text and audio).

4.  **Pronunciation Assistance:**
    * If the user asks you to repeat a translation slowly (e.g., "Say that again slowly," "Can you repeat that?", "Slow down"), repeat *only* the translated phrase from the previous turn.
    * Speak the repeated phrase clearly and at a noticeably slower pace, enunciating carefully to help the user learn. Avoid adding extra conversational text during the slow repetition.

Your primary goal is to be a seamless live translation and language learning assistant, responding accurately and helpfully to the user's specific needs with clear text and natural-sounding spoken audio (including slowed-down audio for pronunciation)."""
                }]
            }
        # Note: The config["generation_config"]["language"] = "en" line below this
        # usually sets the *initial* language Gemini might expect or default to,
        # but the system instruction above should override the rigid swapping behavior.

        # Add language preference to the configuration
        if "generation_config" not in config:
            config["generation_config"] = {}

        # Set English as the default language
        config["generation_config"]["language"] = "en"

        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("Connected to Gemini API")

            async def send_to_gemini():
                """Sends messages from the client websocket to the Gemini API."""
                try:
                  async for message in client_websocket:
                      try:
                          data = json.loads(message)
                          if "realtime_input" in data:
                              for chunk in data["realtime_input"]["media_chunks"]:
                                  if chunk["mime_type"] == "audio/pcm":
                                      save_pcm_as_mp3(base64.b64decode(chunk["data"]),16000, filename="user_input_to_server.mp3")
                                      await session.send({"mime_type": "audio/pcm", "data": chunk["data"]})

                                  elif chunk["mime_type"] == "image/jpeg":
                                      await session.send({"mime_type": "image/jpeg", "data": chunk["data"]})

                      except Exception as e:
                          print(f"Error sending to Gemini: {e}")
                  print("Client connection closed (send)")
                except Exception as e:
                     print(f"Error sending to Gemini: {e}")
                finally:
                   print("send_to_gemini closed")

            async def receive_from_gemini():
                """Receives responses from the Gemini API and forwards them to the client."""
                try:
                    audio_start_sent = False

                    while True:
                        try:
                            accumulated_audio_this_turn = b'' # Accumulate audio for this turn only
                            turn_was_completed = False

                            print("Receiving from Gemini...")
                            async for response in session.receive():
                                if response.server_content is None:
                                    print(f'Unhandled server message! - {response}')
                                    continue

                                model_turn = response.server_content.model_turn
                                if model_turn:
                                    # Send a signal when audio first starts to come in this turn
                                    if not audio_start_sent and any(hasattr(part, 'inline_data') for part in model_turn.parts):
                                        await client_websocket.send(json.dumps({"audio_start": True}))
                                        audio_start_sent = True
                                        print("Sent audio_start signal")

                                    for part in model_turn.parts:
                                        if hasattr(part, 'text') and part.text is not None:
                                            await client_websocket.send(json.dumps({"text": part.text}))
                                            print(f"Sent text: {part.text}")
                                        elif hasattr(part, 'inline_data') and part.inline_data is not None:
                                            print("audio mime_type:", part.inline_data.mime_type)
                                            base64_audio = base64.b64encode(part.inline_data.data).decode('utf-8')

                                            await client_websocket.send(json.dumps({"audio": base64_audio}))

                                            # Accumulate the audio data for this turn
                                            accumulated_audio_this_turn += part.inline_data.data

                                            print(f"Sent audio chunk: {len(part.inline_data.data)} bytes")

                                # Check turn_complete after processing parts
                                if response.server_content.turn_complete:
                                    print('\n<Turn complete signal received from Gemini>')
                                    turn_was_completed = True

                                    # Send turn_complete signal to Flutter immediately
                                    await client_websocket.send(json.dumps({"turn_complete": True}))
                                    print("Sent turn_complete signal to client")

                                    # Reset for next turn
                                    audio_start_sent = False

                                    # Perform transcription after signaling turn_complete
                                    if accumulated_audio_this_turn:
                                        print(f"Attempting transcription for {len(accumulated_audio_this_turn)} bytes...")
                                        # Pass 24kHz sample rate to the transcription function
                                        transcribed_text = transcribe_audio(accumulated_audio_this_turn, sample_rate=24000)
                                        if transcribed_text:
                                            # Send transcription text separately
                                            await client_websocket.send(json.dumps({"text": f"[Transcription]: {transcribed_text}"}))
                                            print(f"Sent transcription result: {transcribed_text}")
                                        else:
                                            print("Transcription failed or produced no text.")
                                            await client_websocket.send(json.dumps({"text": "[Transcription]: <Not recognizable>"}))
                                    # Clear buffer for this turn
                                    accumulated_audio_this_turn = b''
                                    # Break the inner loop for this turn as it's complete
                                    break # Exit inner async for loop

                            # If the inner loop finished because the turn completed, continue the outer loop
                            if turn_was_completed:
                                print("Turn completed, continuing to listen for next interaction...")
                                continue
                            else:
                                # If the inner loop finished for another reason, break outer loop
                                print("Inner receive loop finished without turn_complete signal.")
                                break # Exit while True loop

                        except websockets.exceptions.ConnectionClosedOK:
                            print("Client connection closed normally (receive loop)")
                            break  # Exit the outer loop if the client disconnects
                        except Exception as e:
                            print(f"Error in receive_from_gemini inner loop: {e}")
                            break # Exit outer loop on error

                except Exception as e:
                      print(f"Error in receive_from_gemini outer setup: {e}")
                finally:
                      print("receive_from_gemini task finished.")

            # Start send loop
            send_task = asyncio.create_task(send_to_gemini())
            # Launch receive loop as a background task
            receive_task = asyncio.create_task(receive_from_gemini())
            await asyncio.gather(send_task, receive_task)

    except Exception as e:
        print(f"Error in Gemini session: {e}")
    finally:
        print("Gemini session closed.")

def transcribe_audio(audio_data, sample_rate=24000):
    """Transcribes audio using Gemini 1.5 Flash."""
    try:
        # Make sure we have valid audio data
        if not audio_data:
            print("No audio data received for transcription")
            return None # Return None instead of string message
            
        # Convert PCM to MP3
        save_pcm_as_mp3(audio_data, sample_rate=sample_rate, filename="gemini_output_for_transcription.mp3")
        mp3_audio_base64 = convert_pcm_to_mp3(audio_data, sample_rate=sample_rate)
        if not mp3_audio_base64:
            print("Failed to convert PCM to MP3")
            return None
            
        # Create a client specific for transcription
        transcription_client = generative.GenerativeModel(model_name=TRANSCRIPTION_MODEL)
        
        prompt = """Generate a transcript of the speech. 
        Please do not include any other text in the response. 
        If you cannot hear the speech, please only say '<Not recognizable>'."""
        
        try:
            response = transcription_client.generate_content(
                [
                    prompt,
                    {
                        "mime_type": "audio/mp3", 
                        "data": base64.b64decode(mp3_audio_base64),
                    }
                ]
            )
            
            print(f"Transcription API response text: {response.text}")
            
            # Check if the response is meaningful before returning
            if response.text and response.text.strip() and response.text != '<Not recognizable>':
                return response.text
            else:
                return None
                
        except Exception as e:
            print(f"Error during transcription API call: {e}")
            return None

    except Exception as e:
        print(f"Transcription error: {e}")
        return None

def save_pcm_as_mp3(pcm_data, sample_rate, filename="output.mp3"):
    """Saves PCM audio data as an MP3 file locally."""
    try:
        # Convert PCM to WAV format in memory
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # Mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(sample_rate)  # Set sample rate to match recording
            wav_file.writeframes(pcm_data)
        
        # Reset buffer position
        wav_buffer.seek(0)

        # Convert WAV to MP3
        audio_segment = AudioSegment.from_wav(wav_buffer)
        audio_segment.export(filename, format="mp3", codec="libmp3lame")
        
        print(f"MP3 file saved successfully as {filename}")
        return filename  # Return the filename for reference
    except Exception as e:
        print(f"Error saving PCM as MP3: {e}")
        return None


def convert_pcm_to_mp3(pcm_data, sample_rate=24000):
    """Converts PCM audio to base64 encoded MP3."""
    try:
        # Create a WAV in memory first
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(sample_rate)  # Use the provided sample rate
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
    async with websockets.serve(gemini_session_handler, "0.0.0.0", 9083):
        print("Running websocket server on 0.0.0.0:9083...")
        await asyncio.Future()  # Keep the server running indefinitely


if __name__ == "__main__":
    asyncio.run(main())