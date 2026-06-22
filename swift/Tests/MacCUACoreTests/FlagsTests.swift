import XCTest
@testable import MacCUACore

// Ports the intent of tests/test_feature_flags.py. The Python pipeline-level
// tests (focus enforcement / SCK / serialize) exercise app.session wiring that
// lives outside this pure-logic target, so only the flag-loading and lookup
// tests (TestFeatureFlagLoading) are portable here, plus parse/override coverage.

final class FlagsTests: XCTestCase {

    // MARK: - test_env_var_override

    func testEnvVarOverride() {
        let env: [String: String] = ["MAC_CUA_FLAG_TREE_PRUNING": "0"]
        let flags = FeatureFlags.load(env: { env[$0] })
        XCTAssertFalse(flags.treePruning)
    }

    func testEnvVarOverrideTruthyVariants() {
        for truthy in ["1", "true", "TRUE", "Yes", "yes"] {
            let env = ["MAC_CUA_FLAG_ALWAYS_SIMULATE_CLICK": truthy]
            let flags = FeatureFlags.load(env: { env[$0] })
            XCTAssertTrue(flags.alwaysSimulateClick, "expected \(truthy) -> true")
        }
        for falsy in ["0", "false", "no", "off", ""] {
            let env = ["MAC_CUA_FLAG_TREE_PRUNING": falsy]
            let flags = FeatureFlags.load(env: { env[$0] })
            XCTAssertFalse(flags.treePruning, "expected \(falsy) -> false")
        }
    }

    // MARK: - test_is_enabled_method

    func testIsEnabledMethod() {
        let flags = FeatureFlags(treePruning: true, focusEnforcement: false)
        XCTAssertTrue(flags.isEnabled("tree_pruning"))
        XCTAssertFalse(flags.isEnabled("focus_enforcement"))
        XCTAssertFalse(flags.isEnabled("nonexistent_flag"))
    }

    // MARK: - test_defaults_are_sensible

    func testDefaultsAreSensible() {
        let flags = FeatureFlags()
        // Default-on features
        XCTAssertTrue(flags.treePruning)
        XCTAssertTrue(flags.focusEnforcement)
        XCTAssertTrue(flags.userInterruptionDetection)
        XCTAssertTrue(flags.screenCaptureKit)
        // Default-off features
        XCTAssertFalse(flags.alwaysSimulateClick)
        XCTAssertFalse(flags.screenshotClassifier)
        XCTAssertFalse(flags.allowForbiddenTargets)
        XCTAssertTrue(flags.transientGraphs)
        XCTAssertTrue(flags.axActionVerification)
        XCTAssertTrue(flags.cgeventActionVerification)
        XCTAssertFalse(flags.transientGraphDebug)
        // Remaining defaults preserved from Python
        XCTAssertTrue(flags.codexTreeStyle)
        XCTAssertTrue(flags.richTextMarkdown)
        XCTAssertTrue(flags.webContentExtraction)
        XCTAssertTrue(flags.menuTracking)
        XCTAssertTrue(flags.systemSelection)
        XCTAssertFalse(flags.pipPreview)
        XCTAssertFalse(flags.personalInstructionsOverridesBuiltin)
        XCTAssertTrue(flags.advancedPruning)
        XCTAssertTrue(flags.confirmedDelivery)
    }

    // MARK: - Config-file loading (features sub-object + top-level fallback)

    func testConfigFeaturesSubObject() {
        let config: [String: Any] = ["features": ["tree_pruning": false, "pip_preview": true]]
        let flags = FeatureFlags.load(config: config, env: { _ in nil })
        XCTAssertFalse(flags.treePruning)
        XCTAssertTrue(flags.pipPreview)
        // Untouched flag keeps its default.
        XCTAssertTrue(flags.focusEnforcement)
    }

    func testConfigTopLevelFallback() {
        // No "features" key -> the top-level dict is used directly.
        let config: [String: Any] = ["focus_enforcement": false]
        let flags = FeatureFlags.load(config: config, env: { _ in nil })
        XCTAssertFalse(flags.focusEnforcement)
    }

    func testEnvOverridesConfig() {
        let config: [String: Any] = ["features": ["tree_pruning": true]]
        let env = ["MAC_CUA_FLAG_TREE_PRUNING": "0"]
        let flags = FeatureFlags.load(config: config, env: { env[$0] })
        XCTAssertFalse(flags.treePruning, "env override should win over config")
    }

    // MARK: - WorkaroundFlags

    func testWorkaroundDefaults() {
        let w = WorkaroundFlags()
        XCTAssertEqual(w.loopStepLimit, 20)
        XCTAssertFalse(w.meetingNotesInCalendar)
        XCTAssertFalse(w.shortenLinksForDemo)
    }

    func testWorkaroundConfigAndEnv() {
        let config: [String: Any] = [
            "workarounds": ["loop_step_limit": 5, "shorten_links_for_demo": true]
        ]
        let w = WorkaroundFlags.load(config: config, env: { _ in nil })
        XCTAssertEqual(w.loopStepLimit, 5)
        XCTAssertTrue(w.shortenLinksForDemo)

        let env = ["MAC_CUA_WORKAROUND_LOOP_STEP_LIMIT": "42"]
        let w2 = WorkaroundFlags.load(config: config, env: { env[$0] })
        XCTAssertEqual(w2.loopStepLimit, 42, "env int override should win")
    }

    func testWorkaroundInvalidIntEnvIgnored() {
        let env = ["MAC_CUA_WORKAROUND_LOOP_STEP_LIMIT": "notanint"]
        let w = WorkaroundFlags.load(env: { env[$0] })
        XCTAssertEqual(w.loopStepLimit, 20, "invalid int env should be ignored")
    }
}
