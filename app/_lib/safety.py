"""Safety blocklists — app and URL blocking."""

from __future__ import annotations

import ipaddress
import logging
import socket
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

# System security processes that must never be automated.
BLOCKED_APPS: frozenset[str] = frozenset({
    "com.apple.keychainaccess",
    "com.apple.SecurityAgent",
    "com.apple.Passwords",
    "com.apple.ScreenSharingAgent",
    "com.apple.UserNotificationCenter",
})

_BLOCKED_NETWORKS: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = [
    ipaddress.IPv4Network("127.0.0.0/8"),
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
    ipaddress.IPv4Network("169.254.0.0/16"),
    ipaddress.IPv6Network("::1/128"),
    ipaddress.IPv6Network("fc00::/7"),
    ipaddress.IPv6Network("fe80::/10"),
]

SESSION_STOP_SAFETY = (
    "This session has been stopped because Automation is not allowed on the "
    "current browser URL. Stop your work and send a final message noting why "
    "the session has been ended."
)
SESSION_STOP_USER = (
    "This application session has been explicitly stopped by the user for this "
    "turn. Stop your work and send a final message noting they stopped the "
    "session and you're ready to continue if they want you to. Automation "
    "can be used again in the next assistant turn."
)


class SafetyBlocklist:
    """App and URL blocking for safety."""

    def __init__(self, allow_forbidden: bool = False) -> None:
        self._allow_forbidden = allow_forbidden

    def check_app(self, bundle_id: str) -> str | None:
        """Returns block reason or None if allowed."""
        if self._allow_forbidden:
            return None
        if bundle_id in BLOCKED_APPS:
            return (
                f"Automation is not allowed for system security "
                f"process: {bundle_id}"
            )
        return None

    def check_url(self, url: str) -> str | None:
        """Returns block reason or None. Includes SSRF protection."""
        if self._allow_forbidden:
            return None
        try:
            parsed = urlparse(url)
            hostname = parsed.hostname
            if hostname is None:
                return None
            if self.is_private_ip(hostname):
                return f"private_ip_blocked: {hostname}"
        except Exception:
            return None
        return None

    def is_private_ip(self, hostname: str) -> bool:
        """Resolve hostname and check against private IP ranges."""
        try:
            addr = ipaddress.ip_address(hostname)
            return any(addr in net for net in _BLOCKED_NETWORKS)
        except ValueError:
            pass
        try:
            results = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
            for family, _, _, _, sockaddr in results:
                ip_str = sockaddr[0]
                try:
                    addr = ipaddress.ip_address(ip_str)
                    if any(addr in net for net in _BLOCKED_NETWORKS):
                        return True
                except ValueError:
                    continue
        except socket.gaierror:
            pass
        return False
