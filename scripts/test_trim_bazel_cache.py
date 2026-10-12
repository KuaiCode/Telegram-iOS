import os
import tempfile
import unittest
from pathlib import Path

from trim_bazel_cache import trim_cache


class TrimBazelCacheTests(unittest.TestCase):
    def test_keeps_recent_entries_within_limit_and_preserves_other_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "bazel-cache"
            old = cache / "cas" / "aa" / "old"
            recent = cache / "ac" / "bb" / "recent"
            outside = root / "artifact.ipa"
            for path, content in [(old, b"old data"), (recent, b"new"), (outside, b"IPA")]:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            os.utime(old, (100, 100))
            os.utime(recent, (200, 200))

            self.assertEqual(trim_cache(cache, 3), 3)
            self.assertFalse(old.exists())
            self.assertEqual(recent.read_bytes(), b"new")
            self.assertEqual(outside.read_bytes(), b"IPA")
            self.assertEqual(trim_cache(cache, 3), 3)
            self.assertEqual(trim_cache(cache, 0), 0)

    def test_empty_cache_and_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            self.assertEqual(trim_cache(cache, 1), 0)
            with self.assertRaises(ValueError):
                trim_cache(cache, -1)
            with self.assertRaises(ValueError):
                trim_cache(cache / "missing", 1)

    def test_rejects_symlinks_before_deleting_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "bazel-cache"
            cache.mkdir()
            outside = root / "outside"
            outside.write_bytes(b"keep")
            entry = cache / "entry"
            entry.write_bytes(b"cached")
            try:
                (cache / "link").symlink_to(outside)
            except OSError:
                self.skipTest("Creating symlinks is not permitted")
            with self.assertRaises(ValueError):
                trim_cache(cache, 0)
            self.assertEqual(outside.read_bytes(), b"keep")
            self.assertEqual(entry.read_bytes(), b"cached")


if __name__ == "__main__":
    unittest.main()
