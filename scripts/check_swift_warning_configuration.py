"""Check the pinned Swift rules patch and warning flags without invoking a compiler."""

import ast
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[1]
rules = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build-system/bazel-rules/rules_swift"
relative_source = Path("swift/toolchains/config/compile_config.bzl")
patch = root / "build-system/patches/rules-swift-dump-ast-warning-policy.patch"

module = ast.parse((root / "MODULE.bazel").read_text())
overrides = [
    {keyword.arg: ast.literal_eval(keyword.value) for keyword in node.keywords}
    for node in ast.walk(module)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    and node.func.id == "git_override"
]
override = next(item for item in overrides if item["module_name"] == "rules_swift")
pin = subprocess.check_output(
    ["git", "ls-tree", "HEAD", "build-system/bazel-rules/rules_swift"], cwd=root, text=True
).split()[2]
assert override["commit"] == pin, "The override must retain the pinned rules_swift commit"
assert override["remote"] == "https://github.com/bazelbuild/rules_swift.git"
assert override["patches"] == ["//build-system:patches/" + patch.name]
assert override["patch_strip"] == 1

with tempfile.TemporaryDirectory(prefix="swift-warning-check-") as directory:
    destination = Path(directory) / relative_source
    destination.parent.mkdir(parents=True)
    shutil.copyfile(rules / relative_source, destination)
    subprocess.run(["git", "apply", "--check", "-p1", str(patch)], cwd=directory, check=True)
    subprocess.run(["git", "apply", "-p1", str(patch)], cwd=directory, check=True)
    patched_source = destination.read_text()

configs = [
    node for node in ast.walk(ast.parse(patched_source))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    and node.func.id == "ActionConfigInfo"
]
dump_flags = []
for config in configs:
    keywords = {keyword.arg: keyword.value for keyword in config.keywords}
    actions = keywords.get("actions")
    if "features" in keywords or not isinstance(actions, ast.List):
        continue
    if not any(isinstance(action, ast.Name) and action.id == "SWIFT_ACTION_DUMP_AST" for action in actions.elts):
        continue
    for node in ast.walk(keywords["configurators"]):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "add_arg":
            if node.args and isinstance(node.args[0], ast.Constant):
                dump_flags.append(node.args[0].value)
assert "-dump-ast" in dump_flags, "The patch must preserve AST generation"
assert "-suppress-warnings" not in dump_flags, "AST flags conflict with -Wwarning"

rc_lines = (root / ".bazelrc").read_text().splitlines()
swift_flags = [
    line.split("=", 1)[1] for line in rc_lines
    if line.startswith("build:macos --@build_bazel_rules_swift//swift:copt=")
]
assert swift_flags == ["-Wwarning", "DeprecatedDeclaration"]
assert "build:macos --copt=-Wno-error=deprecated-declarations" in rc_lines
for relative_path in ["submodules/TelegramCore/FlatBuffers/BUILD", "third-party/Swift2D/BUILD", "third-party/XMLCoder/BUILD"]:
    tree = ast.parse((root / relative_path).read_text())
    assert not any(isinstance(node, ast.Constant) and node.value == "-suppress-warnings" for node in ast.walk(tree)), relative_path

print("Passed: fixed rules_swift revision, clean patch application, AST flags, and Swift/Clang warning settings.")
