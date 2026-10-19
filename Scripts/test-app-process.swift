#!/usr/bin/env swift
/*******************************************************************************
 * Memory Boost app-list helper checks (sort + protect filter).
 *
 * Run:
 *   swift Scripts/test-app-process.swift
 ******************************************************************************/

import Foundation

// MARK: - Minimal copies of helpers under test

struct AppProcessListItem: Equatable
{
    let pid: Int32
    let name: String
    let residentBytes: UInt64
    let startedAt: UInt64
}

enum DevPortSupport
{
    static func isProtected( pid: Int32, name: String = "", path: String = "" ) -> Bool
    {
        if pid <= 1
        {
            return true
        }

        let lowerName = name.trimmingCharacters( in: .whitespaces ).lowercased()
        let lowerPath = path.trimmingCharacters( in: .whitespaces ).lowercased()
        let protectedNames: Set<String> = [
            "kernel_task", "launchd", "windowserver", "loginwindow", "hot",
        ]

        if protectedNames.contains( lowerName )
        {
            return true
        }

        if lowerPath.hasSuffix( "/windowserver" )
            || lowerPath.hasSuffix( "/loginwindow" )
            || lowerPath.hasSuffix( "/launchd" )
        {
            return true
        }

        return false
    }
}

enum AppProcessSupport
{
    static func sortedByMemoryDescending( _ items: [ AppProcessListItem ] ) -> [ AppProcessListItem ]
    {
        items.sorted
        {
            lhs, rhs in
            if lhs.residentBytes != rhs.residentBytes
            {
                return lhs.residentBytes > rhs.residentBytes
            }

            if lhs.name != rhs.name
            {
                return lhs.name.localizedCaseInsensitiveCompare( rhs.name ) == .orderedAscending
            }

            return lhs.pid < rhs.pid
        }
    }

    static func filterKillable( _ items: [ AppProcessListItem ] ) -> [ AppProcessListItem ]
    {
        items.filter
        {
            item in
            !DevPortSupport.isProtected( pid: item.pid, name: item.name )
        }
    }

    static func formatBytes( _ bytes: UInt64 ) -> String
    {
        let formatter           = ByteCountFormatter()
        formatter.allowedUnits  = [ .useKB, .useMB, .useGB ]
        formatter.countStyle    = .memory
        formatter.allowsNonnumericFormatting = false

        return formatter.string( fromByteCount: Int64( truncatingIfNeeded: bytes ) )
    }
}

// MARK: - Harness

var failures = 0

func expect( _ condition: @autoclosure () -> Bool, _ message: String )
{
    if condition()
    {
        print( "OK  \( message )" )
    }
    else
    {
        failures += 1
        print( "FAIL \( message )" )
    }
}

let fixture: [ AppProcessListItem ] = [
    AppProcessListItem( pid: 100, name: "Chrome", residentBytes: 500_000_000, startedAt: 1 ),
    AppProcessListItem( pid: 200, name: "Safari", residentBytes: 800_000_000, startedAt: 2 ),
    AppProcessListItem( pid: 50,  name: "WindowServer", residentBytes: 900_000_000, startedAt: 3 ),
    AppProcessListItem( pid: 1,   name: "launchd", residentBytes: 10_000, startedAt: 4 ),
    AppProcessListItem( pid: 300, name: "Hot", residentBytes: 100_000_000, startedAt: 5 ),
    AppProcessListItem( pid: 400, name: "Alpha", residentBytes: 500_000_000, startedAt: 6 ),
]

let sorted = AppProcessSupport.sortedByMemoryDescending( fixture )
expect( sorted.map( \.pid ) == [ 50, 200, 400, 100, 300, 1 ],
        "sorts by resident memory descending (name then pid on ties)" )

let killable = AppProcessSupport.filterKillable( fixture )
expect( killable.map( \.pid ) == [ 100, 200, 400 ],
        "filters protected system / Hot PIDs out of the killable list" )

let sortedKillable = AppProcessSupport.sortedByMemoryDescending( killable )
expect( sortedKillable.map( \.name ) == [ "Safari", "Alpha", "Chrome" ],
        "killable list stays memory-ordered after filter" )

expect( DevPortSupport.isProtected( pid: 1 )
            && DevPortSupport.isProtected( pid: 50, name: "WindowServer" )
            && DevPortSupport.isProtected( pid: 300, name: "Hot" )
            && !DevPortSupport.isProtected( pid: 100, name: "Chrome" ),
        "protects low PIDs / WindowServer / Hot but not typical GUI apps" )

let formatted = AppProcessSupport.formatBytes( 800_000_000 )
expect( formatted.contains( "MB" ) || formatted.contains( "GB" ),
        "formats resident bytes with ByteCountFormatter memory units (\( formatted ))" )

if failures == 0
{
    print( "\nALL PASSED (\( 5 ) checks)" )
    exit( 0 )
}

print( "\nFAILED: \( failures )" )
exit( 1 )
