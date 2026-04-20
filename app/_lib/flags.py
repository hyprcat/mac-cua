"""Feature flags and workaround flags -- runtime toggle system.

Feature flags control capabilities. Workaround flags are for known issues.
Both are loaded from config file with environment variable overrides.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field, fields
from pathlib import Path

logger = logging.getLogger(__name__)

_DEFAULT_CONFIG_PATH = "~/.config/mac-cua/flags.json"


@dataclass
class FeatureFlags:
    """Runtime feature toggles.

    Env var override: MAC_CUA_FLAG_<UPPER_SNAKE_NAME>=1|0
    """

    always_simulate_click: bool = False
    screenshot_classifier: bool = False
    tree_pruning: bool = True
    codex_tree_style: bool = True
    rich_text_markdown: bool = True
    web_content_extraction: bool = True
    user_interruption_detection: bool = True
    focus_enforcement: bool = True
    screen_capture_kit: bool = True
    menu_tracking: bool = True
    transient_graphs: bool = True
    ax_action_verification: bool = True
    cgevent_action_verification: bool = True
    transient_graph_debug: bool = False
    system_selection: bool = True
    pip_preview: bool = False
    personal_instructions_overrides_builtin: bool = False
    advanced_pruning: bool = True
    allow_forbidden_targets: bool = False
    confirmed_delivery: bool = True  # Confirmed delivery pipeline (on-demand tap activation)

    @classmethod
    def load(cls, config_path: str = _DEFAULT_CONFIG_PATH) -> FeatureFlags:
        """Load from config file, with env var overrides.

        Config file is optional — missing file just uses defaults.
        Env vars: MAC_CUA_FLAG_<FIELD_NAME>=1|0|true|false
        """
        instance = cls()

        # Load from config file
        path = Path(config_path).expanduser()
        if path.exists():
            try:
                data = json.loads(path.read_text())
                feature_data = data.get("features", data)
                for f in fields(cls):
                    if f.name in feature_data:
                        setattr(instance, f.name, bool(feature_data[f.name]))
                logger.debug("Loaded feature flags from %s", path)
            except Exception as e:
                logger.warning("Failed to load feature flags from %s: %s", path, e)

        # Override from environment variables
        for f in fields(cls):
            env_key = f"MAC_CUA_FLAG_{f.name.upper()}"
            env_val = os.environ.get(env_key)
            if env_val is not None:
                setattr(instance, f.name, env_val.lower() in ("1", "true", "yes"))

        return instance

    def is_enabled(self, flag_name: str) -> bool:
        """Runtime flag check by name."""
        return getattr(self, flag_name, False)


@dataclass
class WorkaroundFlags:
    """Runtime workaround flags for known issues.

    Separate from feature flags -- these are temporary fixes.
    """

    loop_step_limit: int = 20
    meeting_notes_in_calendar: bool = False
    shorten_links_for_demo: bool = False

    @classmethod
    def load(cls, config_path: str = _DEFAULT_CONFIG_PATH) -> WorkaroundFlags:
        """Load from config file, with env var overrides."""
        instance = cls()

        path = Path(config_path).expanduser()
        if path.exists():
            try:
                data = json.loads(path.read_text())
                workaround_data = data.get("workarounds", {})
                for f in fields(cls):
                    if f.name in workaround_data:
                        val = workaround_data[f.name]
                        setattr(instance, f.name, type(getattr(instance, f.name))(val))
            except Exception as e:
                logger.warning("Failed to load workaround flags from %s: %s", path, e)

        for f in fields(cls):
            env_key = f"MAC_CUA_WORKAROUND_{f.name.upper()}"
            env_val = os.environ.get(env_key)
            if env_val is not None:
                field_type = type(getattr(instance, f.name))
                if field_type is bool:
                    setattr(instance, f.name, env_val.lower() in ("1", "true", "yes"))
                elif field_type is int:
                    try:
                        setattr(instance, f.name, int(env_val))
                    except ValueError:
                        pass

        return instance


# Global singleton instances — initialized at import time with defaults,
# can be reloaded via load().
feature_flags = FeatureFlags.load()
workaround_flags = WorkaroundFlags.load()
