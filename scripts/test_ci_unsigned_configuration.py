import unittest

from ci_unsigned_configuration import unsigned_configuration


class UnsignedConfigurationTests(unittest.TestCase):
    def test_preserves_brand_and_optional_settings_without_mutating_template(self):
        template = {"bundle_id": "dev.kuaicode.airygram", "enable_siri": False, "sg_config": ""}
        result = unsigned_configuration(template, "12345", "ab" * 16)
        self.assertEqual(result["bundle_id"], template["bundle_id"])
        self.assertFalse(result["enable_siri"])
        self.assertEqual(result["sg_config"], "")
        self.assertEqual(result["api_id"], "12345")
        self.assertEqual(result["api_hash"], "ab" * 16)
        self.assertEqual(result["team_id"], "AAAAAAAAAA")
        self.assertEqual(result["is_appstore_build"], "false")
        self.assertNotIn("api_id", template)

    def test_rejects_missing_invalid_and_injected_credentials_without_echoing_them(self):
        for api_id, api_hash in [
            ("", "ab" * 16), ("0", "ab" * 16), ("-1", "ab" * 16),
            ("1\n", "ab" * 16), ("1", ""), ("1", "x" * 32),
            ('1"; injected', "ab" * 16), ("1", '"\n' + "ab" * 16),
        ]:
            with self.subTest(api_id=api_id, api_hash=api_hash):
                with self.assertRaises(ValueError) as caught:
                    unsigned_configuration({}, api_id, api_hash)
                self.assertNotIn("ab" * 16, str(caught.exception))
                self.assertNotIn("injected", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
