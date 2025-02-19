import unittest
import time
from api import Gemini

class TestMockGemini(unittest.TestCase):
    def setUp(self):
        self.mock = Gemini("not_a_real_key")

    def test_connection(self):
        self.assertTrue(self.mock.test_connection())

    def test_disconnection(self):
        self.mock.disconnect()
        with self.assertRaises(ConnectionError):
            self.mock.conversation("Test")

    def response(self):
        self.assertEqual(self.mock.conversation("Test"), "Message received: Test")

    def timeout(self):
        self.assertRaises(self.mock.latency_simulation(True))

if __name__ == "__main__":
    unittest.main()
