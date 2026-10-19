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

import Foundation

/// One TCP listen row from `lsof -F` (subset used for Dev-port discovery).
struct DevPortLsofEntry: Equatable
{
    let port: Int
    let protocolName: String
    let address: String
    let pid: pid_t
    let processName: String
}

/// Pure helpers: DevGuard-style port set, `lsof -F` parse, protected PIDs.
enum DevPortSupport
{
    /// Same defaults as DevGuard `scripts/stop-all-dev.sh` / Vorssaint Kill Process.
    static let devGuardPorts: Set<Int> = [
        3000, 3001, 3002, 5173, 5174, 5175, 5176, 5199,
    ]

    /// Parses `lsof -F pcnPT` text into listen rows.
    static func parseLsof( _ text: String ) -> [ DevPortLsofEntry ]
    {
        var name     = ""
        var pid: pid_t = 0
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
                    pid     = pid_t( value ) ?? 0
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

                case "T":
                    continue

                default:
                    continue
            }
        }

        return rows.sorted
        {
            $0.port == $1.port ? $0.processName < $1.processName : $0.port < $1.port
        }
    }

    /// Sorted unique TCP listen ports per pid. Non-TCP rows are ignored.
    static func listeningPortsByPID( fromLsof text: String ) -> [ pid_t: [ Int ] ]
    {
        var byPID: [ pid_t: Set<Int> ] = [:]

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

    static func pids( _ listeningByPID: [ pid_t: [ Int ] ], matching group: Set<Int> ) -> [ pid_t ]
    {
        listeningByPID.compactMap
        {
            pid, ports in
            matches( ports, group: group ) ? pid : nil
        }
        .sorted()
    }

    /// Protects kernel, launchd, vital session processes, and Hot itself.
    static func isProtected( pid: pid_t, name: String = "", path: String = "" ) -> Bool
    {
        if pid <= 1 || pid == ProcessInfo.processInfo.processIdentifier
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

    /// Best-effort command name for a pid from the first matching lsof row.
    static func processNamesByPID( fromLsof text: String ) -> [ pid_t: String ]
    {
        var names: [ pid_t: String ] = [:]

        for entry in parseLsof( text ) where entry.protocolName == "TCP"
        {
            if names[ entry.pid ] == nil, !entry.processName.isEmpty
            {
                names[ entry.pid ] = entry.processName
            }
        }

        return names
    }
}
