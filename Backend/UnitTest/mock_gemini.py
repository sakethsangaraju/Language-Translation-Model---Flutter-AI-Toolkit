import time
import random

class MockGemini:
    def __init__(self):
        self.connection = True

    def test_connection(self): #Is it connected?
        return self.connection

    def disconnect(self): #Disconnect to check for auto reconnecting functionality
        self.connection = False

    #Will be expanded to include more data types
    def conversation(self, message): #Testing if the connection is working properly to receive and send messages
        if self.connection == False:
            raise ConnectionError('Disconnected')

        if message:
            self.latency_simulation()
            return "Message received: " + message
        else:
            return "No message received"

    def latency_simulation(self, a=False): #Simulating latency and potential network disconnection in between messages
        if a:
            time.sleep(5) #This long sleep simulates a network disconnection which will raise an exception in the test_module.py
        else:
            time.sleep(random.uniform(0.05, 2))