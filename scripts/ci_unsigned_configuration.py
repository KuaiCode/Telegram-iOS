"""Generate the unsigned CI configuration without storing API credentials in Git."""

import json
import os
from pathlib import Path
import re


def unsigned_configuration(template, api_id, api_hash):
    if not re.fullmatch(r"[1-9][0-9]*", api_id):
        raise ValueError("Set TELEGRAM_API_ID to your positive numeric Telegram API ID.")
    if not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
        raise ValueError("Set TELEGRAM_API_HASH to your 32-character hexadecimal Telegram API hash.")
    return dict(
        template,
        api_id=api_id,
        api_hash=api_hash,
        # Placeholder for unsigned entitlements; replace when re-signing for installation.
        team_id="AAAAAAAAAA",
        is_internal_build="false",
        is_appstore_build="false",
    )


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    template = json.loads((root / "build-system/template_minimal_development_configuration.json").read_text())
    try:
        configuration = unsigned_configuration(
            template,
            os.environ.get("TELEGRAM_API_ID", ""),
            os.environ.get("TELEGRAM_API_HASH", ""),
        )
    except ValueError as error:
        raise SystemExit(str(error)) from None
    output = root / "build-input/ci-unsigned-configuration.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(configuration, indent=2) + "\n")
