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

    /// Fresh `lsof` snapshot filtered to `ports` (default: DevGuard set).
    func discoverListeners( in ports: Set<Int> = DevPortSupport.devGuardPorts ) -> [ DevPortListener ]
    {
        let ( listening, names ) = Self.listeningSnapshot()
        return DevPortSupport.pids( listening, matching: ports ).compactMap
        {
            pid in
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

    private static func listeningSnapshot() -> ( [ pid_t: [ Int ] ], [ pid_t: String ] )
    {
        let output = runLsof()
        return (
            DevPortSupport.listeningPortsByPID( fromLsof: output ),
            DevPortSupport.processNamesByPID( fromLsof: output )
        )
    }

    private static func runLsof() -> String
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
            return ""
        }

        let deadline = Date().addingTimeInterval( 5 )

        while process.isRunning && Date() < deadline
        {
            Thread.sleep( forTimeInterval: 0.05 )
        }

        if process.isRunning
        {
            process.terminate()
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        return String( data: data, encoding: .utf8 ) ?? ""
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
