from __future__ import annotations

import unittest

from app._lib.virtual_cursor import AppType, DeliveryMethod, ActivationPolicy, InputStrategy


class InputStrategyDeliveryTests(unittest.TestCase):
    def test_native_cocoa_uses_cgevent_delivery(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.CGEVENT_PID)

    def test_electron_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_browser_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.BROWSER)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_java_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.JAVA)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_qt_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.QT)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_native_cocoa_activation_is_never(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.activation_policy, ActivationPolicy.NEVER)

    def test_electron_activation_is_retry_only(self) -> None:
        strategy = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy.activation_policy, ActivationPolicy.RETRY_ONLY)

    def test_native_cocoa_popup_activation_is_retry(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.activation_policy_for_popup, ActivationPolicy.RETRY_ONLY)

    def test_alternate_delivery_returns_other_method(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.alternate_delivery_method, DeliveryMethod.SKYLIGHT_SPI)

        strategy2 = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy2.alternate_delivery_method, DeliveryMethod.CGEVENT_PID)


if __name__ == "__main__":
    unittest.main()
