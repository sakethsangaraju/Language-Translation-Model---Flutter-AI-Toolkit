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
        
        # Ensure we have system instructions for translation
        if "system_instruction" not in config:
            config["system_instruction"] = {
                "parts": [{
                    "text": "You are a helpful bilingual assistant that translates between English and Spanish. " +
                            "You are also a helpful assistant that will listen and respond to questions either in english or spanish and teach the user how to respond back." +
                            "When you receive input in English, respond in Spanish. " +
                            "When you receive input in Spanish, respond in English. " +
                            "Always include the translation of what was said in your response."
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
                """Receives responses from the Gemini API and forwards them to the client, looping until turn is complete."""
                try:
                    # Initialize audio_data attribute on session
                    session.audio_data = b''
                    audio_start_sent = False
                    
                    while True:
                        try:
                            print("receiving from gemini")
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
                                                
                                            # Send a turn_complete flag to the client
                                            await client_websocket.send(json.dumps({
                                                "turn_complete": True
                                            }))
                                                
                                            # Clear the accumulated audio data
                                            session.audio_data = b''
                                            audio_start_sent = False
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
        save_pcm_as_mp3(audio_data, sample_rate=24000, filename="gemini_output_to_server.mp3")
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


def convert_pcm_to_mp3(pcm_data):
    """Converts PCM audio to base64 encoded MP3."""
    try:
        # Create a WAV in memory first
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, 'wb') as wav_file:
            wav_file.setnchannels(1)  # mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(16000)  # 24kHz
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