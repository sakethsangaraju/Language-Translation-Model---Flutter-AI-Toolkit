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