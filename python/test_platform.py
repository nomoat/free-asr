"""Offline platform checks: python3 python/test_platform.py (FFmpeg required)."""
import unittest
import free_asr as asr


class PlatformTests(unittest.TestCase):
    def test_aes_known_vector_and_padding(self):
        key = "0123456789ABCDEF0123456789ABCDEF"
        encoded = asr._aes256_ecb_enc(key, b"hello world")
        self.assertEqual(encoded.hex(), "df192fc14dc26bbcc8be0c2f30328d5d")
        self.assertEqual(asr._aes256_ecb_dec(key, encoded), b"hello world")
        with self.assertRaises(RuntimeError):
            asr._aes256_ecb_dec(key, bytes(15))

    def test_ffmpeg_packet_boundaries(self):
        chunks = asr._ffmpeg_opus_chunks(bytes(32000), 5)
        self.assertGreaterEqual(len(chunks), 10)
        self.assertTrue(chunks[0].startswith(b"#!OPUS_RAW_V1\x02\x01\x00"))
        frames = 0
        for i, chunk in enumerate(chunks):
            at = 16 if i == 0 else 0
            while at < len(chunk):
                size = int.from_bytes(chunk[at:at + 2], "little")
                self.assertGreater(size, 0)
                self.assertLessEqual(size, 1275)
                at += 2 + size
                frames += 1
            self.assertEqual(at, len(chunk))
        self.assertGreaterEqual(frames, 50)


if __name__ == "__main__":
    unittest.main()
