/*******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2026, Jean-David Gadina - www.xs-labs.com
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

/// Public SMC four-character temperature key sets for Apple Silicon platforms.
/// Lists are intentionally simplified and may be refined per machine later.
public enum TemperatureSensorKeys
{
    public static let minimumChipTemperature: Double = 10
    public static let gpuKeyPrefix = "Tg"

    public enum Platform: String
    {
        case m1
        case m2
        case m3
        case m4
        case m5
        case unknown
    }

    /// Representative CPU die / efficiency / performance sensor keys (public fourCCs).
    private static let cpuKeysByPlatform: [ Platform: Set< String > ] =
    [
        .m1:
        [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j"
        ],
        .m2:
        [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r"
        ],
        .m3:
        [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v"
        ],
        .m4:
        [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v", "Tp0z"
        ],
        .m5:
        [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v", "Tp0z"
        ]
    ]

    /// Core-oriented subsets used when distinguishing package vs core sensors.
    private static let cpuCoreKeysByPlatform: [ Platform: Set< String > ] =
    [
        .m1: [ "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T" ],
        .m2: [ "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T" ],
        .m3: [ "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T" ],
        .m4: [ "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T" ],
        .m5: [ "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T" ]
    ]

    public static func currentPlatform() -> Platform
    {
        let brand = cpuBrandString().lowercased()

        if brand.contains( "apple m5" ) { return .m5 }
        if brand.contains( "apple m4" ) { return .m4 }
        if brand.contains( "apple m3" ) { return .m3 }
        if brand.contains( "apple m2" ) { return .m2 }
        if brand.contains( "apple m1" ) { return .m1 }

        return .unknown
    }

    public static func isCPUTemperatureKey( _ key: String ) -> Bool
    {
        let platform = currentPlatform()

        if let keys = cpuKeysByPlatform[ platform ]
        {
            return keys.contains( key )
        }

        // Unknown platform: accept common Tp* package sensors.
        return key.hasPrefix( "Tp" ) && key.count == 4
    }

    public static func isCPUCoreKey( _ key: String ) -> Bool
    {
        let platform = currentPlatform()

        if let keys = cpuCoreKeysByPlatform[ platform ]
        {
            return keys.contains( key )
        }

        return isCPUTemperatureKey( key )
    }

    public static func hasCPUCoreSet() -> Bool
    {
        let platform = currentPlatform()

        guard let keys = cpuCoreKeysByPlatform[ platform ]
        else
        {
            return false
        }

        return keys.isEmpty == false
    }

    public static func isGPUTemperatureKey( _ key: String ) -> Bool
    {
        key.hasPrefix( gpuKeyPrefix )
    }

    public static func cpuBrandString() -> String
    {
        var length: size_t = 0

        guard sysctlbyname( "machdep.cpu.brand_string", nil, &length, nil, 0 ) == 0, length > 0
        else
        {
            return ""
        }

        var buffer = [ CChar ]( repeating: 0, count: length )

        guard sysctlbyname( "machdep.cpu.brand_string", &buffer, &length, nil, 0 ) == 0
        else
        {
            return ""
        }

        return String( cString: buffer )
    }
}
