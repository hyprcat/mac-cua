import asyncio
import logging
import sys



PERMISSIONS_PENDING_MESSAGE = (
    "Permissions are still pending. Accessibility and Screen Recording "
    "permissions have not been granted yet. Call this tool again — the user "
    "may still be granting permissions. Do not end your turn."
)


_permissions_prompted = False


def check_permissions_with_retry_guidance() -> str | None:
    """Check AX and Screen Recording permissions.

    On the first call, triggers the system permission dialogs (non-blocking).
    On subsequent calls, just checks without prompting.
    Returns a retry message if not yet granted, None if OK.
    """
    global _permissions_prompted
    from app._lib.accessibility import check_accessibility_permission
    from app._lib.screenshot import check_screen_recording_permission, prompt_screen_recording_permission

    if not _permissions_prompted:
        _permissions_prompted = True
        ax_ok = check_accessibility_permission(prompt=True)
        screen_ok = prompt_screen_recording_permission()
    else:
        ax_ok = check_accessibility_permission()
        screen_ok = check_screen_recording_permission()

    if not ax_ok or not screen_ok:
        return PERMISSIONS_PENDING_MESSAGE
    return None


async def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    from app._lib.analytics import analytics
    analytics.service_launched()

    from app.server import run_server
    await run_server()


if __name__ == "__main__":
    asyncio.run(main())
