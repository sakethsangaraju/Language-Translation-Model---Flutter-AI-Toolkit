from google import genai

import asyncio
import websockets

import tracemalloc

# tracemalloc.start()

key = input("Paste your API key here to proceed")
client = genai.Client(api_key=key)
model = "gemini-1.5-flash"

async def hello(websocket):
    while True:

        # print(tracemalloc.get_traced_memory()) #memory check

        msg = await websocket.recv()

        if msg == "quit":
            break

        echo = f"Message sent: {msg}"
        response = client.models.generate_content(
    model='gemini-2.0-flash', contents= echo)
        text = response.text
        print(text)
        await websocket.send(text)

async def main():
    async with websockets.serve(hello, "localhost", 8765):
        #run forever
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())




