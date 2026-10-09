"""Check the actual patched profile guards for device/simulator and signed/unsigned builds."""

from pathlib import Path
import re
import sys
from types import SimpleNamespace


rules = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build-system/bazel-rules/rules_apple")
source = (rules / "apple/internal/ios_rules.bzl").read_text()
guards = re.findall(
    r"    if ([^\n]+):\n        processor_partials.append\(\n"
    r"            partials.provisioning_profile_partial\(",
    source,
)
assert len(guards) == source.count("partials.provisioning_profile_partial(") == 6
for guard in guards:
    for device in (False, True):
        for unsigned in (False, True):
            actual = eval(guard, {"__builtins__": {}}, {
                "platform_prerequisites": SimpleNamespace(platform=SimpleNamespace(is_device=device)),
                "features": ["disable_legacy_signing"] if unsigned else [],
            })
            assert actual == (device and not unsigned), (guard, device, unsigned)
print("Passed: all 6 profile guards preserve signed-device checks and skip unsigned/simulator builds.")
