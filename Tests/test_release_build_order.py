"""Disposable git histories exercise the actual release build-order guard."""
from pathlib import Path
import subprocess
import tempfile
import unittest


GUARD = Path(__file__).resolve().parents[1] / "Scripts/check_release_build_order.py"


class ReleaseBuildOrderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.STDOUT)

    def release(self, version, build):
        (self.root / "VERSION").write_text(f"MARKETING_VERSION={version}\nBUILD_NUMBER={build}\n")
        self.git("add", "VERSION")
        self.git("commit", "-qm", version)
        self.git("tag", "v" + version)

    def verify(self, feed_version, feed_build, version, build):
        feed = self.root / "appcast.xml"
        feed.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="{feed_build}" sparkle:shortVersionString="{feed_version}"/></item></channel></rss>')
        return subprocess.run(["python3", "-I", str(GUARD), str(feed), version, str(build)], cwd=self.root, capture_output=True, text=True)

    def test_regenerated_feed_cannot_hide_reused_build(self):
        self.release("1.14.0", 18)
        for feed_version in ("1.14.0", "1.15.0"):
            result = self.verify(feed_version, 18, "1.15.0", 18)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must exceed", result.stderr)

    def test_new_build_passes_before_and_after_feed_generation(self):
        self.release("1.14.0", 18)
        self.assertEqual(self.verify("1.14.0", 18, "1.15.0", 19).returncode, 0)
        self.assertEqual(self.verify("1.15.0", 19, "1.15.0", 19).returncode, 0)

    def test_immutable_release_can_be_reverified_after_newer_release(self):
        self.release("1.14.0", 18)
        self.release("1.15.0", 19)
        self.assertEqual(self.verify("1.14.0", 18, "1.14.0", 18).returncode, 0)

    def test_candidate_feed_alone_is_not_published_history(self):
        result = self.verify("1.15.0", 18, "1.15.0", 18)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("independent release history", result.stderr)

    def test_prior_feed_can_supply_history_without_tags(self):
        self.assertNotEqual(self.verify("1.14.0", 18, "1.15.0", 18).returncode, 0)
        self.assertEqual(self.verify("1.14.0", 18, "1.15.0", 19).returncode, 0)


if __name__ == "__main__":
    unittest.main()
