import unittest
import time
from mock_gemini import MockGemini

class TestMockGemini(unittest.TestCase):
    def setUp(self):
        self.mock = MockGemini()

    def test_connection(self):
        self.assertTrue(self.mock.test_connection())

    def test_disconnection(self):
        self.mock.disconnect()
        self.assertRaises(self.mock.conversation("Test"))

    def response(self):
        self.assertEqual(self.mock.conversation("Test"), "Message received: Test")

    def timeout(self):
        self.assertRaises(self.mock.latency_simulation(True))

if __name__ == "__main__":
    api.py()