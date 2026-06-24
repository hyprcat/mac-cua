// Real AppResolver implementation (US-016) — NSWorkspace/lsappinfo-backed app
// resolution that NEVER foregrounds the target (Invariant 14). The only allowed
// re-activation is restoring the USER's previous frontmost app (Invariant 15).
//
// Pure parsing/matching (lsappinfo block parse, name/bundle resolution order)
// lives in MacCUACore.AppResolverParsing so it is Linux-green + fake-tested;
// this file is the thin AppKit/ApplicationServices wrapper around it.

#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import MacCUACore

public final class KitAppResolver: AppResolver {
    private let launchTimeout: TimeInterval

    // apps.py module-level caches (_pid_cache / _ax_app_cache).
    private var pidCache: [String: Int] = [:]
    private var axAppCache: [Int: AXUIElement] = [:]

    public init(launchTimeout: TimeInterval = 30) {
        self.launchTimeout = launchTimeout
    }

    // MARK: - Listing

    public func listRunningApps() -> [AppInfo] {
        var result: [AppInfo] = []
        var seen: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleId = app.bundleIdentifier else { continue }
            // activationPolicy == .regular (0) — regular GUI apps only.
            guard app.activationPolicy == .regular else { continue }
            let name = app.localizedName ?? AppResolverParsing.nameFromBundleId(bundleId)
            seen.insert(bundleId)
            result.append(AppInfo(
                name: name,
                bundleId: bundleId,
                pid: Int(app.processIdentifier),
                running: true
            ))
        }

        // Fallback: lsappinfo finds GUI apps NSWorkspace might miss (e.g. when
        // the MCP server runs as a child of a sandboxed app).
        for parsed in lsAppInfoList() where !seen.contains(parsed.bundleId) {
            result.append(AppInfo(
                name: parsed.name ?? AppResolverParsing.nameFromBundleId(parsed.bundleId),
                bundleId: parsed.bundleId,
                pid: parsed.pid,
                running: true
            ))
            seen.insert(parsed.bundleId)
        }
        return result
    }

    private func lsAppInfoList() -> [ParsedLSApp] {
        guard let out = runCommand("/usr/bin/lsappinfo", ["list"], timeout: 5) else { return [] }
        return AppResolverParsing.parseLSAppInfoList(out)
    }

    public func listRecentApps() -> [AppInfo] {
        let sflPath = (NSString(string:
            "~/Library/Application Support/com.apple.sharedfilelist/"
            + "com.apple.LSSharedFileList.RecentApplications.sfl3"
        ).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: sflPath),
              let data = FileManager.default.contents(atPath: sflPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else {
            return []
        }

        var result: [AppInfo] = []
        for item in items {
            guard let bookmark = item["Bookmark"] as? Data else { continue }
            let name = item["Name"] as? String
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            guard let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier else { continue }
            let resolvedName = (name?.isEmpty == false)
                ? name!
                : AppResolverParsing.nameFromBundleId(bundleId)
            result.append(AppInfo(
                name: resolvedName,
                bundleId: bundleId,
                pid: nil,
                running: false
            ))
        }
        return result
    }

    // MARK: - Resolution

    public func resolveApp(_ hint: String) throws -> AppInfo {
        let running = listRunningApps()
        if let match = AppResolverParsing.matchRunningApp(hint: hint, among: running) {
            return match
        }

        // Not running — if it looks like a bundle id we can locate, return an
        // installed (non-running) entry the caller can launch.
        if hint.contains("."),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hint) {
            var name = AppResolverParsing.nameFromBundleId(hint)
            if let bundle = Bundle(url: appURL),
               let cfName = bundle.infoDictionary?["CFBundleName"] as? String {
                name = cfName
            }
            return AppInfo(name: name, bundleId: hint, pid: nil, running: false)
        }

        throw AutomationError("App not found: \(hint). Use list_apps to see available apps.")
    }

    public func resolveRunningAppByPid(_ pid: Int) -> AppInfo? {
        if let match = listRunningApps().first(where: { $0.pid == pid }) {
            return match
        }
        guard let running = NSRunningApplication(processIdentifier: pid_t(pid)),
              let bundleId = running.bundleIdentifier else {
            return nil
        }
        let name = running.localizedName ?? AppResolverParsing.nameFromBundleId(bundleId)
        return AppInfo(name: name, bundleId: bundleId, pid: pid, running: true)
    }

    // MARK: - Launch (never activates)

    public func launchApp(bundleId: String) throws -> Int {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw AutomationError("Cannot find app with bundle ID: \(bundleId)")
        }

        // Modern AppKit launch with activates=false is Apple's supported way to
        // avoid foreground activation. Fall back to `open -g` (which also never
        // activates) if it fails.
        if !launchWithoutActivation(appURL) {
            if !runOpenG(bundleId: bundleId) {
                throw AutomationError("Failed to launch app without activation: \(bundleId)")
            }
        }

        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            for a in listRunningApps() where a.bundleId == bundleId {
                if let pid = a.pid {
                    pidCache[bundleId] = pid
                    return pid
                }
            }
        }
        throw AutomationError(
            "App \(bundleId) did not appear in process list within \(Int(launchTimeout))s"
        )
    }

    /// Launch with `NSWorkspaceOpenConfiguration.activates = false`. Returns
    /// false if the async launch reported an error.
    private func launchWithoutActivation(_ appURL: URL) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false           // <- the non-foregrounding contract
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false

        // openApplication is async with a completion handler; we only need it to
        // have been dispatched without an immediate failure. The deadline loop
        // in launchApp() is what actually confirms the process appeared.
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        return true
    }

    private func runOpenG(bundleId: String) -> Bool {
        runCommand("/usr/bin/open", ["-g", "-b", bundleId], timeout: 10) != nil
    }

    // MARK: - AX application elements

    public func getAXApp(bundleId: String, knownPid: Int?) throws -> (axApp: AXElementRef, pid: Int) {
        // Validate any cached pid is still alive before reuse.
        if let cachedPid = pidCache[bundleId] {
            if isPidAlive(cachedPid), let ax = axAppCache[cachedPid] {
                return (KitAXElementRef(ax), cachedPid)
            }
            invalidateCaches(forPid: cachedPid)
        }

        var pid = knownPid
        if pid == nil || !isPidAlive(pid!) {
            let info = try resolveApp(bundleId)
            if let livePid = info.pid {
                pid = livePid
            } else {
                pid = try launchApp(bundleId: bundleId)
            }
        }

        let resolvedPid = pid!
        pidCache[bundleId] = resolvedPid
        let ax = AXUIElementCreateApplication(pid_t(resolvedPid))
        axAppCache[resolvedPid] = ax
        return (KitAXElementRef(ax), resolvedPid)
    }

    public func getAXAppForPid(_ pid: Int, bundleId: String?) throws -> (axApp: AXElementRef, pid: Int) {
        guard isPidAlive(pid) else {
            throw AutomationError("PID \(pid) is not running")
        }
        let ax: AXUIElement
        if let cached = axAppCache[pid] {
            ax = cached
        } else {
            ax = AXUIElementCreateApplication(pid_t(pid))
            axAppCache[pid] = ax
        }
        if let bundleId { pidCache[bundleId] = pid }
        return (KitAXElementRef(ax), pid)
    }

    private func invalidateCaches(forPid pid: Int) {
        axAppCache.removeValue(forKey: pid)
        for (bundle, p) in pidCache where p == pid {
            pidCache.removeValue(forKey: bundle)
        }
    }

    // MARK: - Frontmost (the ONLY allowed activation is restore)

    public func getFrontmostApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else {
            return nil
        }
        let name = app.localizedName ?? AppResolverParsing.nameFromBundleId(bundleId)
        return AppInfo(
            name: name,
            bundleId: bundleId,
            pid: Int(app.processIdentifier),
            running: true
        )
    }

    public func restoreFrontmostApp(_ app: AppInfo?) {
        guard let app, let pid = app.pid,
              let sanctionedFrontmostRestore = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return
        }
        // Restoring the user's previous frontmost is the SOLE sanctioned
        // activation (Invariant 15). Skip if it is already active so we never
        // gratuitously re-foreground. The receiver name `sanctionedFrontmostRestore`
        // is what the US-012 banned-symbol guard allowlists for this one site.
        if !sanctionedFrontmostRestore.isActive {
            sanctionedFrontmostRestore.activate(options: [])
        }
    }

    // MARK: - Permissions

    /// Real Accessibility-trust check (US-015). `prompt: true` surfaces the
    /// system Accessibility dialog (non-blocking); `false` just queries. Never
    /// foregrounds — `AXIsProcessTrustedWithOptions` only reads/raises the
    /// settings prompt.
    public func checkAccessibilityPermission(prompt: Bool) -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable global under Swift 6
        // strict concurrency; its documented value is the literal below.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Helpers

    private func isPidAlive(_ pid: Int) -> Bool {
        // kill(pid, 0) — probe without sending a signal (matches apps.py).
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Run a short-lived command, returning stdout or nil on failure/timeout.
    private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Bounded wait so a hung tool can't stall the spine.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
#endif
