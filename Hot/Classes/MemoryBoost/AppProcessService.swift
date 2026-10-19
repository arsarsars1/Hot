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

/// A user GUI app with resident memory and start-time identity for safe quit.
struct AppProcessInfo: Equatable
{
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let residentBytes: UInt64
    let startedAt: UInt64
    /// True when `proc_pidinfo` memory was unavailable (listed with 0 for sorting).
    let memoryUnknown: Bool

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

/// Lists regular GUI apps by resident memory and quits them with identity checks.
final class AppProcessService
{
    static let shared = AppProcessService()

    /// Current `.regular` apps, excluding protected PIDs, sorted by memory desc.
    /// Must be called on the main thread (`NSWorkspace` is main-thread only).
    func listRegularApps() -> [ AppProcessInfo ]
    {
        precondition( Thread.isMainThread, "AppProcessService.listRegularApps requires main thread" )

        let running = NSWorkspace.shared.runningApplications.filter
        {
            app in
            app.activationPolicy == .regular
                && !app.isTerminated
                && app.processIdentifier > 0
        }

        let items: [ AppProcessInfo ] = running.compactMap
        {
            app in
            let pid  = app.processIdentifier
            let name = Self.displayName( for: app )
            let path = app.executableURL?.path ?? app.bundleURL?.path ?? ""

            guard !DevPortSupport.isProtected( pid: pid, name: name, path: path ),
                  let startedAt = Self.currentStartTime( pid: pid )
            else
            {
                return nil
            }

            let resident = Self.residentBytes( pid: pid )
            let bytes    = resident ?? 0

            return AppProcessInfo(
                pid: pid,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                residentBytes: bytes,
                startedAt: startedAt,
                memoryUnknown: resident == nil
            )
        }

        let ordered = AppProcessSupport.sortedByMemoryDescending( items.map( \.listItem ) )
        let byPID   = Dictionary( uniqueKeysWithValues: items.map { ( $0.pid, $0 ) } )

        return ordered.compactMap { byPID[ $0.pid ] }
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

        guard let running = NSRunningApplication( processIdentifier: pid ),
              !running.isTerminated
        else
        {
            return .alreadyGone
        }

        guard Self.currentStartTime( pid: pid ) == app.startedAt
        else
        {
            return .stale
        }

        let ok = force ? running.forceTerminate() : running.terminate()

        return ok ? .quit : .failed
    }

    // MARK: - Helpers

    private static func displayName( for app: NSRunningApplication ) -> String
    {
        if let raw = app.localizedName?.trimmingCharacters( in: .whitespacesAndNewlines ),
           raw.isEmpty == false
        {
            // Strip bidi marks some App Store titles include (e.g. WhatsApp).
            return String( raw.unicodeScalars.filter { $0.value != 0x200E && $0.value != 0x200F } )
        }

        if let bundle = app.bundleURL?.deletingPathExtension().lastPathComponent
        {
            return bundle
        }

        return "pid \( app.processIdentifier )"
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
