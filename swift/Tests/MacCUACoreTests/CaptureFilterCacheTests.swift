import XCTest
@testable import MacCUACore

final class CaptureFilterCacheTests: XCTestCase {
    private func sig(pid: Int = 100, x: Double = 0, y: Double = 0,
                     w: Double = 800, h: Double = 600, title: String? = "Doc") -> CapturedWindowSignature {
        CapturedWindowSignature(ownerPid: pid, bounds: Rect(x: x, y: y, w: w, h: h), title: title)
    }

    func testStoreThenHitOnMatchingSignature() {
        let cache = CaptureFilterCache<String>()
        let s = sig()
        cache.store("filter-A", forWindowId: 42, signature: s)
        XCTAssertEqual(cache.value(forWindowId: 42, signature: s), "filter-A")
        XCTAssertEqual(cache.count, 1)
    }

    func testMissOnUnknownWindow() {
        let cache = CaptureFilterCache<String>()
        XCTAssertNil(cache.value(forWindowId: 7, signature: sig()))
    }

    func testWindowReplaceEvictsOnSignatureMismatch() {
        let cache = CaptureFilterCache<String>()
        cache.store("filter-A", forWindowId: 42, signature: sig(pid: 100))
        // Same id, different owner pid => recycled window id, must miss + evict.
        XCTAssertNil(cache.value(forWindowId: 42, signature: sig(pid: 200)))
        XCTAssertEqual(cache.count, 0)
        // Subsequent lookup with the original signature also misses (evicted).
        XCTAssertNil(cache.value(forWindowId: 42, signature: sig(pid: 100)))
    }

    func testBoundsChangeIsAReplace() {
        let cache = CaptureFilterCache<String>()
        cache.store("filter-A", forWindowId: 1, signature: sig(w: 800))
        XCTAssertNil(cache.value(forWindowId: 1, signature: sig(w: 1024)))
    }

    func testTitleChangeIsAReplace() {
        let cache = CaptureFilterCache<String>()
        cache.store("filter-A", forWindowId: 1, signature: sig(title: "Old"))
        XCTAssertNil(cache.value(forWindowId: 1, signature: sig(title: "New")))
    }

    func testInvalidateSingleWindow() {
        let cache = CaptureFilterCache<String>()
        cache.store("A", forWindowId: 1, signature: sig())
        cache.store("B", forWindowId: 2, signature: sig(pid: 200))
        cache.invalidate(windowId: 1)
        XCTAssertNil(cache.value(forWindowId: 1, signature: sig()))
        XCTAssertEqual(cache.value(forWindowId: 2, signature: sig(pid: 200)), "B")
        XCTAssertEqual(cache.count, 1)
    }

    func testInvalidateAllClearsAndBumpsGeneration() {
        let cache = CaptureFilterCache<String>()
        cache.store("A", forWindowId: 1, signature: sig())
        cache.store("B", forWindowId: 2, signature: sig(pid: 200))
        XCTAssertEqual(cache.generation, 0)
        cache.invalidateAll()
        XCTAssertEqual(cache.generation, 1)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(forWindowId: 1, signature: sig()))
    }

    func testStoreReplacesExistingEntry() {
        let cache = CaptureFilterCache<String>()
        cache.store("A", forWindowId: 1, signature: sig())
        cache.store("A2", forWindowId: 1, signature: sig())
        XCTAssertEqual(cache.value(forWindowId: 1, signature: sig()), "A2")
        XCTAssertEqual(cache.count, 1)
    }

    func testGenerationMonotonicAcrossMultipleInvalidations() {
        let cache = CaptureFilterCache<String>()
        cache.invalidateAll()
        cache.invalidateAll()
        cache.invalidateAll()
        XCTAssertEqual(cache.generation, 3)
    }
}
