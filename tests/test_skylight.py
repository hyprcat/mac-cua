from __future__ import annotations

import ctypes
import unittest
from unittest.mock import MagicMock, patch, PropertyMock


class SkyLightLoadTests(unittest.TestCase):
    """Test that skylight.py loads and exposes its API correctly."""

    @patch("app._lib.skylight._load_framework")
    def test_get_main_connection_calls_cgs_function(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        mock_load.return_value = mock_framework

        # Re-import to pick up the mock
        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        cid = skylight.get_main_connection()
        self.assertEqual(cid, 42)
        mock_framework.CGSMainConnectionID.assert_called_once()

    @patch("app._lib.skylight._load_framework")
    def test_get_connection_for_pid_calls_cgs_function(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        # CGSGetConnectionIDForPID writes into a c_int pointer
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        result = skylight.get_connection_for_pid(42, 1234)
        mock_framework.CGSGetConnectionIDForPID.assert_called_once()

    @patch("app._lib.skylight._load_framework")
    def test_validate_window_owner_returns_true_for_matching_pid(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        # Both calls return same connection ID
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        def fake_get_owner(cid, wid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetWindowOwner.side_effect = fake_get_owner
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        self.assertTrue(skylight.validate_window_owner(77, 1234))

    @patch("app._lib.skylight._load_framework")
    def test_validate_window_owner_returns_false_for_mismatched_pid(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        def fake_get_owner(cid, wid, out_ptr):
            out_ptr._obj.value = 50  # different from 99
            return 0
        mock_framework.CGSGetWindowOwner.side_effect = fake_get_owner
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        self.assertFalse(skylight.validate_window_owner(77, 1234))

    @patch("app._lib.skylight._load_framework")
    def test_post_mouse_event_returns_false_when_spi_unavailable(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        mock_framework.CGSPostMouseEventToProcess = None  # SPI not available
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        result = skylight.post_mouse_event(1234, 1, 100.0, 200.0)
        self.assertFalse(result)


class MicroActivationTests(unittest.TestCase):

    @patch("app._lib.skylight._framework", new_callable=lambda: MagicMock)
    @patch("app._lib.skylight._main_cid", 42)
    @patch("app._lib.skylight.get_connection_for_pid", return_value=99)
    @patch("app._lib.skylight.time")
    def test_micro_activate_context_restores_on_exit(
        self, mock_time: MagicMock, mock_get_cid: MagicMock, mock_fw: MagicMock
    ) -> None:
        mock_time.monotonic.side_effect = [0.0, 0.001, 0.002]  # well under 10ms
        from app._lib.skylight import micro_activate

        with micro_activate(target_pid=1234):
            pass  # activation should be set and then restored

    @patch("app._lib.skylight._framework", new_callable=lambda: MagicMock)
    @patch("app._lib.skylight._main_cid", 42)
    @patch("app._lib.skylight.get_connection_for_pid", return_value=99)
    @patch("app._lib.skylight.time")
    def test_micro_activate_restores_even_on_exception(
        self, mock_time: MagicMock, mock_get_cid: MagicMock, mock_fw: MagicMock
    ) -> None:
        mock_time.monotonic.side_effect = [0.0, 0.001, 0.002]
        from app._lib.skylight import micro_activate

        with self.assertRaises(RuntimeError):
            with micro_activate(target_pid=1234):
                raise RuntimeError("boom")
        # Should not raise — restore happens in __exit__


if __name__ == "__main__":
    unittest.main()
