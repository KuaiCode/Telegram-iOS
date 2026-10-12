import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build-system" / "Make"))
import Make


class BuildAnalysisTests(unittest.TestCase):
    def arguments(self, analyze_only, output_path=None):
        return SimpleNamespace(
            overrideBazelVersion=False, overrideXcodeVersion=False, bazelUserRoot=None,
            lock=False, cacheDir=None, cacheHost=None, configuration="release_arm64",
            embedWatchApp=False, buildNumber=10001, target="//Telegram:Swiftgram",
            continueOnError=True, showActions=False, sandbox=False, profileSwift=False,
            enableParallelSwiftmoduleGeneration=False, analyzeOnly=analyze_only,
            outputBuildArtifactsPath=output_path,
        )

    def setUp(self):
        environment = patch.object(Make, "BuildEnvironment", return_value=SimpleNamespace(bazel_path="bazel"))
        configuration = patch.object(Make, "resolve_configuration")
        environment.start()
        configuration.start()
        self.addCleanup(environment.stop)
        self.addCleanup(configuration.stop)

    def test_analysis_uses_the_same_release_build_command_except_nobuild(self):
        with patch.object(Make, "call_executable") as execute:
            Make.build("bazel", self.arguments(False))
            build_command = execute.call_args.args[0]
            Make.build("bazel", self.arguments(True))
            analysis_command = execute.call_args.args[0]
        self.assertIn("--nobuild", analysis_command)
        self.assertEqual([arg for arg in analysis_command if arg != "--nobuild"], build_command)
        self.assertIn("//Telegram:Swiftgram", analysis_command)
        self.assertIn("--ios_multi_cpus=arm64", analysis_command)
        self.assertIn("--define=buildNumber=10001", analysis_command)

    def test_analysis_does_not_export_or_delete_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Swiftgram.ipa"
            ipa.write_bytes(b"existing IPA")
            with patch.object(Make, "call_executable"):
                Make.build("bazel", self.arguments(True, directory))
            self.assertEqual(ipa.read_bytes(), b"existing IPA")
            self.assertEqual(list(Path(directory).iterdir()), [ipa])

    def test_analysis_failure_is_not_treated_as_success(self):
        with patch.object(Make, "call_executable", side_effect=SystemExit(1)):
            with self.assertRaises(SystemExit) as caught:
                Make.build("bazel", self.arguments(True))
        self.assertEqual(caught.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
