from __future__ import annotations

import unittest

from app._lib.safety import SafetyBlocklist


class TestSafetyBlocklistApps(unittest.TestCase):
    def setUp(self) -> None:
        self.blocklist = SafetyBlocklist()

    def test_blocks_keychain_access(self) -> None:
        result = self.blocklist.check_app("com.apple.keychainaccess")
        self.assertIsNotNone(result)
        self.assertIn("system security process", result)

    def test_blocks_security_agent(self) -> None:
        result = self.blocklist.check_app("com.apple.SecurityAgent")
        self.assertIsNotNone(result)

    def test_allows_normal_app(self) -> None:
        result = self.blocklist.check_app("com.apple.Music")
        self.assertIsNone(result)

    def test_allows_normal_app_with_flag(self) -> None:
        blocklist = SafetyBlocklist(allow_forbidden=True)
        result = blocklist.check_app("com.apple.keychainaccess")
        self.assertIsNone(result)


class TestSafetyBlocklistURLs(unittest.TestCase):
    def setUp(self) -> None:
        self.blocklist = SafetyBlocklist()

    def test_blocks_localhost_url(self) -> None:
        result = self.blocklist.check_url("http://127.0.0.1:8080/api")
        self.assertIsNotNone(result)
        self.assertIn("private_ip_blocked", result)

    def test_blocks_private_10_range(self) -> None:
        result = self.blocklist.check_url("http://10.0.0.1/admin")
        self.assertIsNotNone(result)

    def test_blocks_private_172_range(self) -> None:
        result = self.blocklist.check_url("http://172.16.0.1/")
        self.assertIsNotNone(result)

    def test_blocks_private_192_range(self) -> None:
        result = self.blocklist.check_url("http://192.168.1.1/")
        self.assertIsNotNone(result)

    def test_blocks_ipv6_loopback(self) -> None:
        result = self.blocklist.check_url("http://[::1]:3000/")
        self.assertIsNotNone(result)

    def test_allows_public_url(self) -> None:
        result = self.blocklist.check_url("https://www.example.com/page")
        self.assertIsNone(result)

    def test_allows_with_flag(self) -> None:
        blocklist = SafetyBlocklist(allow_forbidden=True)
        result = blocklist.check_url("http://127.0.0.1/")
        self.assertIsNone(result)

    def test_is_private_ip_direct(self) -> None:
        self.assertTrue(self.blocklist.is_private_ip("127.0.0.1"))
        self.assertTrue(self.blocklist.is_private_ip("10.255.0.1"))
        self.assertFalse(self.blocklist.is_private_ip("8.8.8.8"))

    def test_handles_malformed_url(self) -> None:
        result = self.blocklist.check_url("not-a-url")
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
