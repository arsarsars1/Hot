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

/// macOS diagnostics inspired by `iOSCrashReporter` / `PluginCrashReporter`.
///
/// Capture-only: breadcrumbs + manual reports to stderr/NSLog and a rolling log file.
/// The CocoaPods plugin targets iOS/UIKit and cannot be linked into this app.
enum FanControlDiagnostics
{
    private static let lock = NSLock()
    private static var crumbs: [ String ] = []
    private static let crumbCapacity = 64
    private static let iso8601: ISO8601DateFormatter =
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [ .withInternetDateTime ]
        return formatter
    }()

    static func leaveBreadcrumb( category: String, message: String, data: [ String: String ] = [:] )
    {
        let stamp = iso8601.string( from: Date() )
        let payload = data.isEmpty
            ? ""
            : " " + data.map { "\($0.key)=\($0.value)" }.sorted().joined( separator: " " )
        let line = "[\( stamp )] [\( category )] \( message )\( payload )"

        lock.lock()
        if crumbs.count >= crumbCapacity
        {
            crumbs.removeFirst()
        }
        crumbs.append( line )
        lock.unlock()

        NSLog( "[HotFanControl] %@", line )
        appendToFile( line )
    }

    static func report( _ title: String, detail: String, location: String? = nil )
    {
        let whereText = location.map { " where=\( $0 )" } ?? ""
        let line = "ERROR \( title ): \( detail )\( whereText )"
        leaveBreadcrumb( category: "error", message: line )

        lock.lock()
        let snapshot = crumbs
        lock.unlock()

        let joined = snapshot.joined( separator: "\n" )
        NSLog( "[HotFanControl] REPORT %@ — crumbs:\n%@", title, joined )
        appendToFile( "---- report \( title ) ----\n\( joined )\n---- end ----" )
    }

    static func logFileURL() -> URL
    {
        let folder = FileManager.default.urls( for: .libraryDirectory, in: .userDomainMask ).first!
            .appendingPathComponent( "Logs/Hot", isDirectory: true )
        try? FileManager.default.createDirectory( at: folder, withIntermediateDirectories: true )
        return folder.appendingPathComponent( "fan-control.log" )
    }

    private static func appendToFile( _ line: String )
    {
        let url = logFileURL()
        let data = ( line + "\n" ).data( using: .utf8 ) ?? Data()

        if FileManager.default.fileExists( atPath: url.path ) == false
        {
            try? data.write( to: url, options: .atomic )
            return
        }

        guard let handle = try? FileHandle( forWritingTo: url )
        else
        {
            return
        }
        defer
        {
            handle.closeFile()
        }
        handle.seekToEndOfFile()
        handle.write( data )
    }
}
