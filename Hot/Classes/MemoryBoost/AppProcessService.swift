/*******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2026 Hot contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the Software), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED AS IS, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

import AppKit
import Darwin
import Foundation

/// A process with resident memory and start-time identity for safe quit.
struct AppProcessInfo: Equatable
{
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let residentBytes: UInt64
    let startedAt: UInt64
    /// True when `proc_pidinfo` memory was unavailable (listed with 0 for sorting).
    let memoryUnknown: Bool
    /// Whether this is a `.regular` GUI app (Quit uses AppKit terminate).
    let isRegularApp: Bool

    var listItem: AppProcessListItem
    {
        AppProcessListItem(
            pid: self.pid,
            name: self.name,
            residentBytes: self.residentBytes,
            startedAt: self.startedAt
        )
    }
}

enum AppQuitResult: Equatable
{
    case quit
    case alreadyGone
    case failed
    case protected
    case stale
}

/// Cached process enumeration for stale-while-revalidate UI.
struct AppProcessSnapshot: Equatable
{
    let apps: [ AppProcessInfo ]
    let fetchedAt: Date
}

/// Lists processes by resident memory and quits them with identity checks.
final class AppProcessService
{
    static let shared = AppProcessService()

    /// Closed-sidebar warm interval (utility QoS).
    static let closedWarmInterval: TimeInterval = 14.0
    /// Fresh enough for open-path paint without forcing a scan.
    static let openMaxAge: TimeInterval = 3.0

    private let lock = NSLock()
    private var _cachedSnapshot: AppProcessSnapshot?
    private var refreshCompletions: [ ( AppProcessSnapshot ) -> Void ] = []
    private var refreshInFlight = false
    private var warmTimer: DispatchSourceTimer?
    private var warmingStarted = false

    /// Thread-safe last good snapshot (may be nil before first warm).
    var cachedSnapshot: AppProcessSnapshot?
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._cachedSnapshot
    }

    /// Start deferred + periodic background warming (idempotent). Call once after launch.
    func startBackgroundWarming( deferred: TimeInterval = 1.0 )
    {
        self.lock.lock()
        let already = self.warmingStarted
        if already == false
        {
            self.warmingStarted = true
        }
        self.lock.unlock()

        guard already == false
        else
        {
            return
        }

        DispatchQueue.global( qos: .utility ).asyncAfter( deadline: .now() + deferred )
        {
            [ weak self ] in
            self?.refreshIfNeeded( maxAge: 0, completion: { _ in } )
            self?.installWarmTimer()
        }
    }

    /// Stop closed-cadence warming (e.g. on terminate).
    func stopBackgroundWarming()
    {
        self.lock.lock()
        self.warmingStarted = false
        let timer = self.warmTimer
        self.warmTimer = nil
        self.lock.unlock()
        timer?.cancel()
    }

    /// Single-flight refresh. If cache age ≤ `maxAge`, returns it immediately on a background queue.
    /// Completions always run off the main thread; callers hop to main for UI.
    func refreshIfNeeded( maxAge: TimeInterval, completion: @escaping ( AppProcessSnapshot ) -> Void )
    {
        self.lock.lock()
        if let snap = self._cachedSnapshot,
           maxAge > 0,
           Date().timeIntervalSince( snap.fetchedAt ) <= maxAge
        {
            self.lock.unlock()
            DispatchQueue.global( qos: .utility ).async
            {
                completion( snap )
            }
            return
        }

        self.refreshCompletions.append( completion )

        if self.refreshInFlight
        {
            self.lock.unlock()
            return
        }

        self.refreshInFlight = true
        self.lock.unlock()

        DispatchQueue.global( qos: .utility ).async
        {
            [ weak self ] in
            guard let self = self
            else
            {
                return
            }

            let apps = self.listProcessesByMemory()
            let snap = AppProcessSnapshot( apps: apps, fetchedAt: Date() )

            self.lock.lock()
            self._cachedSnapshot = snap
            let waiters = self.refreshCompletions
            self.refreshCompletions = []
            self.refreshInFlight = false
            self.lock.unlock()

            for waiter in waiters
            {
                waiter( snap )
            }
        }
    }

    /// All non-protected processes with readable memory, sorted high → low.
    /// Safe off the main thread (uses `proc_listpids` + optional `NSRunningApplication`).
    func listProcessesByMemory() -> [ AppProcessInfo ]
    {
        let pids = Self.allPIDs()
        var items: [ AppProcessInfo ] = []
        items.reserveCapacity( min( pids.count, 256 ) )

        for pid in pids
        {
            guard pid > 0
            else
            {
                continue
            }

            let path = Self.processPath( pid: pid ) ?? ""
            let running = NSRunningApplication( processIdentifier: pid )
            let name = Self.displayName( pid: pid, path: path, running: running )

            guard !DevPortSupport.isProtected( pid: pid, name: name, path: path ),
                  let startedAt = Self.currentStartTime( pid: pid )
            else
            {
                continue
            }

            let resident = Self.residentBytes( pid: pid )
            // Skip zombies / unreadable — keep only processes we can rank by RAM.
            guard let bytes = resident
            else
            {
                continue
            }

            let isRegular = running?.activationPolicy == .regular

            items.append(
                AppProcessInfo(
                    pid: pid,
                    name: name,
                    bundleIdentifier: running?.bundleIdentifier,
                    residentBytes: bytes,
                    startedAt: startedAt,
                    memoryUnknown: false,
                    isRegularApp: isRegular
                )
            )
        }

        let ordered = AppProcessSupport.sortedByMemoryDescending( items.map( \.listItem ) )
        let byPID   = Dictionary( uniqueKeysWithValues: items.map { ( $0.pid, $0 ) } )

        return ordered.compactMap { byPID[ $0.pid ] }
    }

    /// Back-compat alias used by older call sites / tests.
    func listRegularApps() -> [ AppProcessInfo ]
    {
        self.listProcessesByMemory()
    }

    // MARK: - Warm timer

    private func installWarmTimer()
    {
        self.lock.lock()
        guard self.warmingStarted, self.warmTimer == nil
        else
        {
            self.lock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource( queue: DispatchQueue.global( qos: .utility ) )
        timer.schedule(
            deadline: .now() + Self.closedWarmInterval,
            repeating: Self.closedWarmInterval,
            leeway: .seconds( 2 )
        )
        timer.setEventHandler
        {
            [ weak self ] in
            self?.refreshIfNeeded( maxAge: Self.closedWarmInterval * 0.75, completion: { _ in } )
        }
        self.warmTimer = timer
        self.lock.unlock()
        timer.resume()
    }

    /// Quit (or force-quit) after start-time identity revalidation.
    @discardableResult
    func quit( _ app: AppProcessInfo, force: Bool = false ) -> AppQuitResult
    {
        let pid = app.pid

        if DevPortSupport.isProtected( pid: pid, name: app.name )
        {
            return .protected
        }

        guard Self.currentStartTime( pid: pid ) == app.startedAt
        else
        {
            return Self.pidStillAlive( pid ) ? .stale : .alreadyGone
        }

        if let running = NSRunningApplication( processIdentifier: pid ),
           !running.isTerminated,
           running.activationPolicy == .regular
        {
            guard Self.currentStartTime( pid: pid ) == app.startedAt
            else
            {
                return .stale
            }

            let ok = force ? running.forceTerminate() : running.terminate()

            return ok ? .quit : .failed
        }

        let signal = force ? SIGKILL : SIGTERM

        guard Self.currentStartTime( pid: pid ) == app.startedAt
        else
        {
            return .stale
        }

        if Darwin.kill( pid, signal ) == 0
        {
            return .quit
        }

        switch errno
        {
            case ESRCH:
                return .alreadyGone

            default:
                return .failed
        }
    }

    // MARK: - Enumeration

    private static func allPIDs() -> [ pid_t ]
    {
        let type = UInt32( PROC_ALL_PIDS )
        let bytesNeeded = proc_listpids( type, 0, nil, 0 )

        guard bytesNeeded > 0
        else
        {
            return []
        }

        let count = Int( bytesNeeded ) / MemoryLayout<pid_t>.size
        var buffer = [ pid_t ]( repeating: 0, count: count )
        let filled = proc_listpids( type, 0, &buffer, Int32( bytesNeeded ) )

        guard filled > 0
        else
        {
            return []
        }

        let live = Int( filled ) / MemoryLayout<pid_t>.size

        return Array( buffer.prefix( live ) )
    }

    private static func processPath( pid: pid_t ) -> String?
    {
        var path = [ CChar ]( repeating: 0, count: Int( MAXPATHLEN ) )
        let result = proc_pidpath( pid, &path, UInt32( MAXPATHLEN ) )

        guard result > 0
        else
        {
            return nil
        }

        return String( cString: path )
    }

    private static func processName( pid: pid_t ) -> String?
    {
        var name = [ CChar ]( repeating: 0, count: Int( 2 * MAXCOMLEN ) )
        let result = proc_name( pid, &name, UInt32( name.count ) )

        guard result > 0
        else
        {
            return nil
        }

        let raw = String( cString: name ).trimmingCharacters( in: .whitespacesAndNewlines )

        return raw.isEmpty ? nil : raw
    }

    private static func displayName( pid: pid_t, path: String, running: NSRunningApplication? ) -> String
    {
        if let raw = running?.localizedName?.trimmingCharacters( in: .whitespacesAndNewlines ),
           raw.isEmpty == false
        {
            return String( raw.unicodeScalars.filter { $0.value != 0x200E && $0.value != 0x200F } )
        }

        if let bundle = running?.bundleURL?.deletingPathExtension().lastPathComponent,
           bundle.isEmpty == false
        {
            return bundle
        }

        if let name = processName( pid: pid )
        {
            return name
        }

        if path.isEmpty == false
        {
            return URL( fileURLWithPath: path ).lastPathComponent
        }

        return "pid \( pid )"
    }

    static func residentBytes( pid: pid_t ) -> UInt64?
    {
        var info = proc_taskinfo()
        let size = Int32( MemoryLayout<proc_taskinfo>.size )

        guard proc_pidinfo( pid, PROC_PIDTASKINFO, 0, &info, size ) == size
        else
        {
            return nil
        }

        return info.pti_resident_size
    }

    static func currentStartTime( pid: pid_t ) -> UInt64?
    {
        var info = proc_bsdinfo()
        let size = Int32( MemoryLayout<proc_bsdinfo>.size )

        guard proc_pidinfo( pid, PROC_PIDTBSDINFO, 0, &info, size ) == size
        else
        {
            return nil
        }

        return info.pbi_start_tvsec &* 1_000_000 &+ UInt64( info.pbi_start_tvusec )
    }

    private static func pidStillAlive( _ pid: pid_t ) -> Bool
    {
        Darwin.kill( pid, 0 ) == 0 || errno == EPERM
    }
}
