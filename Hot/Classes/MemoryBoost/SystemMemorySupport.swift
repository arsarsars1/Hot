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

import Darwin
import Foundation

/// Snapshot of physical memory pressure (best-effort, Activity Monitor–style).
struct SystemMemorySnapshot: Equatable
{
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64

    var usedFraction: Double
    {
        guard self.totalBytes > 0
        else
        {
            return 0
        }

        return min( 1, Double( self.usedBytes ) / Double( self.totalBytes ) )
    }

    var usedPercent: Int
    {
        Int( ( self.usedFraction * 100 ).rounded() )
    }
}

enum SystemMemorySupport
{
    /// Reads host VM stats. Safe to call from any thread.
    static func snapshot() -> SystemMemorySnapshot
    {
        let total = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        host_page_size( mach_host_self(), &pageSize )

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer( to: &stats )
        {
            pointer in
            pointer.withMemoryRebound( to: integer_t.self, capacity: Int( count ) )
            {
                host_statistics64( mach_host_self(), HOST_VM_INFO64, $0, &count )
            }
        }

        guard kr == KERN_SUCCESS, pageSize > 0
        else
        {
            return SystemMemorySnapshot(
                totalBytes: total,
                usedBytes: 0,
                freeBytes: total,
                wiredBytes: 0,
                compressedBytes: 0
            )
        }

        let page = UInt64( pageSize )
        let free = ( UInt64( stats.free_count ) + UInt64( stats.speculative_count ) ) * page
        let wired = UInt64( stats.wire_count ) * page
        let compressed = UInt64( stats.compressor_page_count ) * page
        // App-used approx: active + inactive + wired + compressed (matches common menu-bar meters).
        let used = min(
            total,
            ( UInt64( stats.active_count )
                + UInt64( stats.inactive_count )
                + UInt64( stats.wire_count )
                + UInt64( stats.compressor_page_count ) ) * page
        )

        return SystemMemorySnapshot(
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            wiredBytes: wired,
            compressedBytes: compressed
        )
    }

    static func formatBytes( _ bytes: UInt64 ) -> String
    {
        AppProcessSupport.formatBytes( bytes )
    }

    static func summaryLine( _ snap: SystemMemorySnapshot ) -> String
    {
        "\( formatBytes( snap.usedBytes ) ) of \( formatBytes( snap.totalBytes ) )"
    }
}
