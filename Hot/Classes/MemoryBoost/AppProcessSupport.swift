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

/// Lightweight row used for sorting / protection checks (pure helpers).
struct AppProcessListItem: Equatable
{
    let pid: pid_t
    let name: String
    let residentBytes: UInt64
    let startedAt: UInt64
}

/// Pure helpers for Memory Boost app listing (sortable without AppKit).
enum AppProcessSupport
{
    /// Sort by resident memory descending; ties break on name then pid.
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

    /// Drop protected PIDs / names (reuses Dev-port protection rules).
    static func filterKillable( _ items: [ AppProcessListItem ] ) -> [ AppProcessListItem ]
    {
        items.filter
        {
            item in
            !DevPortSupport.isProtected( pid: item.pid, name: item.name )
        }
    }

    /// Human-readable memory size (binary units).
    static func formatBytes( _ bytes: UInt64 ) -> String
    {
        let formatter           = ByteCountFormatter()
        formatter.allowedUnits  = [ .useKB, .useMB, .useGB ]
        formatter.countStyle    = .memory
        formatter.allowsNonnumericFormatting = false

        return formatter.string( fromByteCount: Int64( truncatingIfNeeded: bytes ) )
    }
}
