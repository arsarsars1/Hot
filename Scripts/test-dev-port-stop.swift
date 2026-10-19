#!/usr/bin/env swift
/*******************************************************************************
 * Dev-port stop / memory-boost helper checks (pure parse + group logic).
 *
 * Run:
 *   swift Scripts/test-dev-port-stop.swift
 ******************************************************************************/

import Foundation

// MARK: - Minimal copies of helpers under test

struct DevPortLsofEntry: Equatable
{
    let port: Int
    let protocolName: String
    let address: String
    let pid: Int32
    let processName: String
}

enum DevPortSupport
{
    static let devGuardPorts: Set<Int> = [
        3000, 3001, 3002, 5173, 5174, 5175, 5176, 5199,
    ]

    static func parseLsof( _ text: String ) -> [ DevPortLsofEntry ]
    {
        var name     = ""
        var pid: Int32 = 0
        var address  = ""
        var port     = 0
        var proto    = "TCP"
        var rows: [ DevPortLsofEntry ] = []
        var seen     = Set<String>()

        for line in text.split( separator: "\n" ).map( String.init )
        {
            guard let type = line.first
            else
            {
                continue
            }

            let value = String( line.dropFirst() )

            switch type
            {
                case "p":
                    pid     = Int32( value ) ?? 0
                    port    = 0
                    address = ""

                case "c":
                    name = value

                case "P":
                    proto = value

                case "n":
                    address = value
                    guard let last = value.split( separator: ":" ).last,
                          let parsed = Int( last )
                    else
                    {
                        port = 0
                        continue
                    }

                    port = parsed

                    if pid > 0 && port > 0
                    {
                        let key = "\( proto )|\( port )|\( address )|\( pid )"

                        if seen.insert( key ).inserted
                        {
                            rows.append(
                                DevPortLsofEntry(
                                    port: port,
                                    protocolName: proto,
                                    address: address,
                                    pid: pid,
                                    processName: name
                                )
                            )
                        }
                    }

                default:
                    continue
            }
        }

        return rows.sorted
        {
            $0.port == $1.port ? $0.processName < $1.processName : $0.port < $1.port
        }
    }

    static func listeningPortsByPID( fromLsof text: String ) -> [ Int32: [ Int ] ]
    {
        var byPID: [ Int32: Set<Int> ] = [:]

        for entry in parseLsof( text ) where entry.protocolName == "TCP"
        {
            byPID[ entry.pid, default: [] ].insert( entry.port )
        }

        return byPID.mapValues { $0.sorted() }
    }

    static func matches( _ ports: [ Int ], group: Set<Int> ) -> Bool
    {
        ports.contains { group.contains( $0 ) }
    }

    static func ports( _ ports: [ Int ], in group: Set<Int> ) -> [ Int ]
    {
        ports.filter { group.contains( $0 ) }.sorted()
    }

    static func pids( _ listeningByPID: [ Int32: [ Int ] ], matching group: Set<Int> ) -> [ Int32 ]
    {
        listeningByPID.compactMap
        {
            pid, ports in
            matches( ports, group: group ) ? pid : nil
        }
        .sorted()
    }

    static func isProtected( pid: Int32, name: String = "" ) -> Bool
    {
        if pid <= 1
        {
            return true
        }

        let lowerName = name.trimmingCharacters( in: .whitespaces ).lowercased()
        let protectedNames: Set<String> = [
            "kernel_task", "launchd", "windowserver", "loginwindow", "hot",
        ]

        return protectedNames.contains( lowerName )
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

let listenFixture = """
p100
cnode
PTCP
n127.0.0.1:3000
n*:5173
p200
cvite
PTCP
n*:5199
p300
cother
PTCP
n*:8080
p400
cmdns
PUDP
n*:5353
"""

let byPID = DevPortSupport.listeningPortsByPID( fromLsof: listenFixture )
expect( byPID[ 100 ] == [ 3000, 5173 ] && byPID[ 200 ] == [ 5199 ] && byPID[ 300 ] == [ 8080 ],
        "aggregates sorted unique TCP listen ports per pid" )
expect( byPID[ 400 ] == nil, "ignores non-TCP listeners" )

let group = DevPortSupport.devGuardPorts
expect( group == Set( [ 3000, 3001, 3002, 5173, 5174, 5175, 5176, 5199 ] ),
        "DevGuard stop-all-dev ports are the default group" )
expect( DevPortSupport.matches( [ 3000, 8080 ], group: group )
            && !DevPortSupport.matches( [ 8080 ], group: group ),
        "port-group matching requires at least one shared listen port" )
expect( DevPortSupport.ports( [ 8080, 5173, 3000 ], in: group ) == [ 3000, 5173 ],
        "port-group intersection stays sorted" )
expect( DevPortSupport.pids( byPID, matching: group ) == [ 100, 200 ],
        "port-group PID discovery skips listeners outside the group" )
expect( DevPortSupport.isProtected( pid: 1 ) && DevPortSupport.isProtected( pid: 50, name: "WindowServer" )
            && !DevPortSupport.isProtected( pid: 100, name: "node" ),
        "protects system PIDs / names but not typical Dev listeners" )

if failures == 0
{
    print( "\nALL PASSED (\( 7 ) checks)" )
    exit( 0 )
}

print( "\nFAILED: \( failures )" )
exit( 1 )
