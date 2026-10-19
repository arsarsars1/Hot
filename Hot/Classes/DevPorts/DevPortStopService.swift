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

/// A listener discovered on a Dev port, with start-time identity for safe kill.
struct DevPortListener: Equatable
{
    let pid: pid_t
    let processName: String
    let ports: [ Int ]
    let startedAt: UInt64
}

/// Cached Dev-port listener snapshot for stale-while-revalidate UI.
struct DevPortListenerSnapshot: Equatable
{
    let listeners: [ DevPortListener ]
    let fetchedAt: Date
}

enum DevPortStopResult: Equatable
{
    case nothingToStop
    case stopped( Set<pid_t> )
    case partial( stopped: Set<pid_t>, failed: [ pid_t ] )
}

/// Discovers TCP listeners on common Dev ports and stops them with SIGTERM
/// after start-time identity revalidation (same safety idea as Vorssaint Kill Process).
final class DevPortStopService
{
    static let shared = DevPortStopService()

    /// Open-sidebar TTL for listener cache (~5s).
    static let openMaxAge: TimeInterval = 5.0
    /// Closed-sidebar warm interval (~15s).
    static let closedWarmInterval: TimeInterval = 15.0
    /// Back-compat alias for open-path max age.
    static let defaultMaxAge: TimeInterval = DevPortStopService.openMaxAge

    private let lock = NSLock()
    private var _cachedSnapshot: DevPortListenerSnapshot?
    private var refreshCompletions: [ ( DevPortListenerSnapshot ) -> Void ] = []
    private var refreshInFlight = false
    private var warmTimer: DispatchSourceTimer?
    private var warmingStarted = false

    private struct KillTarget: Equatable
    {
        let pid: pid_t
        let startedAt: UInt64
    }

    private enum DirectKillResult
    {
        case killed
        case alreadyGone
        case failed
        case stale
    }

    private enum LsofCapture
    {
        case success( String )
        case failed
    }

    /// Thread-safe last good listener snapshot.
    var cachedSnapshot: DevPortListenerSnapshot?
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._cachedSnapshot
    }

    /// Start deferred + periodic closed-cadence warming (idempotent). Call once after launch.
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

    /// Single-flight `lsof` refresh. Completions run off the main thread.
    /// On `lsof` timeout/failure, keeps the last good cache (fail soft).
    func refreshIfNeeded( maxAge: TimeInterval = DevPortStopService.openMaxAge,
                          ports: Set<Int> = DevPortSupport.devGuardPorts,
                          completion: @escaping ( DevPortListenerSnapshot ) -> Void )
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

            let snap = self.captureListeners( in: ports )

            self.lock.lock()
            if let snap = snap
            {
                self._cachedSnapshot = snap
            }
            let deliver = snap ?? self._cachedSnapshot
                ?? DevPortListenerSnapshot( listeners: [], fetchedAt: Date() )
            let waiters = self.refreshCompletions
            self.refreshCompletions = []
            self.refreshInFlight = false
            self.lock.unlock()

            for waiter in waiters
            {
                waiter( deliver )
            }
        }
    }

    /// Fresh `lsof` snapshot filtered to `ports` (default: DevGuard set).
    /// Returns `[]` if `lsof` fails or times out (does not mutate cache).
    func discoverListeners( in ports: Set<Int> = DevPortSupport.devGuardPorts ) -> [ DevPortListener ]
    {
        self.captureListeners( in: ports )?.listeners ?? []
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

    /// Parses a successful `lsof` capture into listeners; `nil` on fail/timeout.
    private func captureListeners( in ports: Set<Int> ) -> DevPortListenerSnapshot?
    {
        switch Self.runLsof()
        {
            case .failed:
                return nil

            case .success( let output ):
                let listening = DevPortSupport.listeningPortsByPID( fromLsof: output )
                let names = DevPortSupport.processNamesByPID( fromLsof: output )
                let listeners = DevPortSupport.pids( listening, matching: ports ).compactMap
                {
                    pid -> DevPortListener? in
                    guard !DevPortSupport.isProtected( pid: pid, name: names[ pid ] ?? "" ),
                          let startedAt = Self.currentStartTime( pid: pid )
                    else
                    {
                        return nil
                    }

                    let matched = DevPortSupport.ports( listening[ pid ] ?? [], in: ports )

                    return DevPortListener(
                        pid: pid,
                        processName: names[ pid ] ?? "pid \( pid )",
                        ports: matched,
                        startedAt: startedAt
                    )
                }

                return DevPortListenerSnapshot( listeners: listeners, fetchedAt: Date() )
        }
    }

    /// Re-reads `lsof`, builds identity-checked targets, sends SIGTERM (or SIGKILL if `force`).
    /// Call from a background queue; no admin elevation (EPERM counts as failure).
    @discardableResult
    func stopListeners( in ports: Set<Int> = DevPortSupport.devGuardPorts,
                        force: Bool = false ) -> DevPortStopResult
    {
        let listeners = discoverListeners( in: ports )

        guard !listeners.isEmpty
        else
        {
            return .nothingToStop
        }

        let targets = listeners.map
        {
            KillTarget( pid: $0.pid, startedAt: $0.startedAt )
        }

        var stopped = Set<pid_t>()
        var failed: [ pid_t ] = []

        for target in targets
        {
            guard !DevPortSupport.isProtected( pid: target.pid ),
                  Self.identityMatches( target )
            else
            {
                failed.append( target.pid )
                continue
            }

            switch Self.attemptDirectKill( target: target, force: force )
            {
                case .killed, .alreadyGone:
                    stopped.insert( target.pid )

                case .failed, .stale:
                    failed.append( target.pid )
            }
        }

        if stopped.isEmpty && !failed.isEmpty
        {
            return .partial( stopped: [], failed: failed )
        }

        if failed.isEmpty
        {
            return .stopped( stopped )
        }

        return .partial( stopped: stopped, failed: failed )
    }

    // MARK: - Snapshot / identity

    /// Runs `lsof` with a hard timeout; `.failed` on launch error or slow kill.
    private static func runLsof() -> LsofCapture
    {
        let process            = Process()
        process.executableURL  = URL( fileURLWithPath: "/usr/sbin/lsof" )
        process.arguments      = [ "-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT" ]
        let pipe               = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()

        do
        {
            try process.run()
        }
        catch
        {
            return .failed
        }

        let deadline = Date().addingTimeInterval( 5 )

        while process.isRunning && Date() < deadline
        {
            Thread.sleep( forTimeInterval: 0.05 )
        }

        if process.isRunning
        {
            process.terminate()
            return .failed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        return .success( String( data: data, encoding: .utf8 ) ?? "" )
    }

    private static func currentStartTime( pid: pid_t ) -> UInt64?
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

    private static func identityMatches( _ target: KillTarget ) -> Bool
    {
        currentStartTime( pid: target.pid ) == target.startedAt
    }

    private static func attemptDirectKill( target: KillTarget, force: Bool ) -> DirectKillResult
    {
        guard identityMatches( target )
        else
        {
            return .stale
        }

        let pid = target.pid

        if let running = NSRunningApplication( processIdentifier: pid ),
           !running.isTerminated,
           running.activationPolicy == .regular
        {
            guard identityMatches( target )
            else
            {
                return .stale
            }

            let ok = force ? running.forceTerminate() : running.terminate()

            return ok ? .killed : .failed
        }

        let signal = force ? SIGKILL : SIGTERM

        guard identityMatches( target )
        else
        {
            return .stale
        }

        if Darwin.kill( pid, signal ) == 0
        {
            return .killed
        }

        switch errno
        {
            case ESRCH:
                return .alreadyGone

            default:
                return .failed
        }
    }
}
