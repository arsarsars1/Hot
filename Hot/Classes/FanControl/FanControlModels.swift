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

struct FanControlFanReading: Codable, Equatable
{
    let index: Int
    let actualRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let isManuallyControlled: Bool
}

enum FanControlMode: String, Codable
{
    case system
    case manual
    case curve
}

enum FanControlTemperatureSource: String, Codable, CaseIterable
{
    case averageSoC
    case hottestSoC
    case averageCPU
    case hottestCPU
    case hottestGPU
}

struct FanControlTemperatureReading: Codable, Equatable
{
    let source: FanControlTemperatureSource
    let celsius: Double
}

struct FanControlCurvePoint: Codable, Equatable
{
    var temperature: Int
    var coolingLevel: Int
}

struct FanControlCurve: Codable, Equatable
{
    var sensor: FanControlTemperatureSource
    var points: [ FanControlCurvePoint ]
}

struct FanControlConfiguration: Codable, Equatable
{
    var mode: FanControlMode
    var manualLevel: Int
    var curves: [ FanControlCurve ]

    static let defaultCurve = FanControlCurve(
        sensor: .hottestSoC,
        points: [
            FanControlCurvePoint( temperature: 50, coolingLevel: 0 ),
            FanControlCurvePoint( temperature: 70, coolingLevel: 100 ),
        ]
    )

    static func manual( level: Int ) -> FanControlConfiguration
    {
        FanControlConfiguration( mode: .manual, manualLevel: level, curves: [] )
    }

    static func curve( _ curves: [ FanControlCurve ] ) -> FanControlConfiguration
    {
        FanControlConfiguration(
            mode: .curve,
            manualLevel: FanControlPolicy.defaultCoolingLevel,
            curves: curves
        )
    }

    static func encodeCurves( _ curves: [ FanControlCurve ] ) -> String?
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [ .sortedKeys ]
        guard let data = try? encoder.encode( curves )
        else
        {
            return nil
        }
        return String( data: data, encoding: .utf8 )
    }

    static func decodeCurves( _ value: String ) -> [ FanControlCurve ]?
    {
        guard let data = value.data( using: .utf8 ),
              let curves = try? JSONDecoder().decode( [ FanControlCurve ].self, from: data ),
              FanControlPolicy.validCurves( curves )
        else
        {
            return nil
        }
        return curves
    }

    static var defaultCurvesStorage: String
    {
        encodeCurves( [ defaultCurve ] ) ?? "[]"
    }
}

struct FanControlSnapshot: Codable, Equatable
{
    var fans: [ FanControlFanReading ]
    var isCooling: Bool
    var endsAt: Date?
    var stopReason: FanControlStopReason?
    var coolingLevel: Int?
    var configuration: FanControlConfiguration?
    var temperatures: [ FanControlTemperatureReading ]?

    static let empty = FanControlSnapshot(
        fans: [],
        isCooling: false,
        endsAt: nil,
        stopReason: nil,
        coolingLevel: nil,
        configuration: nil,
        temperatures: nil
    )
}

enum FanControlStopReason: String, Codable, Equatable
{
    case timeLimit
    case appDisconnected
    case heartbeatLost
    case hardwareChanged
    case thermalPressure
    case temperatureUnavailable
    case recovery
}

enum FanControlErrorCode: String, Codable, Equatable, Error
{
    case noFans
    case unsupportedHardware
    case alreadyControlled
    case authorizationRequired
    case helperUnavailable
    case controlFailed
}

struct FanControlResponse: Codable, Equatable
{
    let succeeded: Bool
    let snapshot: FanControlSnapshot
    let error: FanControlErrorCode?

    static func success( _ snapshot: FanControlSnapshot ) -> FanControlResponse
    {
        FanControlResponse( succeeded: true, snapshot: snapshot, error: nil )
    }

    static func failure( _ error: FanControlErrorCode, snapshot: FanControlSnapshot = .empty ) -> FanControlResponse
    {
        FanControlResponse( succeeded: false, snapshot: snapshot, error: error )
    }
}

enum FanControlPolicy
{
    static let heartbeatLimit: TimeInterval = 7
    static let verificationFailureLimit = 3
    static let temperatureFailureLimit = 3
    static let maximumFanCount = 8
    static let maximumSaneRPM = 20_000.0
    static let minimumCoolingLevel = 0
    static let maximumCoolingLevel = 100
    static let coolingLevelStep = 5
    static let defaultCoolingLevel = maximumCoolingLevel
    static let minimumCurveTemperature = 20
    static let maximumCurveTemperature = 110
    static let minimumCurvePointCount = 2
    static let maximumCurvePointCount = 8
    static let maximumCurveCount = FanControlTemperatureSource.allCases.count
    static let curveHysteresis = 2.0

    static func isAutomaticMode( _ mode: UInt8 ) -> Bool
    {
        mode == 0 || mode == 3
    }

    static func fanCount( from value: Double ) -> Int?
    {
        guard value.isFinite
        else
        {
            return nil
        }
        let rounded = value.rounded()
        guard abs( value - rounded ) < 0.001
        else
        {
            return nil
        }
        let count = Int( rounded )
        return ( 1 ... maximumFanCount ).contains( count ) ? count : nil
    }

    static func validBounds( minimum: Double, maximum: Double ) -> Bool
    {
        minimum.isFinite && maximum.isFinite
            && minimum >= 0 && maximum > minimum && maximum <= maximumSaneRPM
    }

    static func validReading( _ value: Double ) -> Bool
    {
        value.isFinite && value >= 0 && value <= maximumSaneRPM
    }

    static func validCoolingLevel( _ level: Int ) -> Bool
    {
        ( minimumCoolingLevel ... maximumCoolingLevel ).contains( level )
            && level.isMultiple( of: coolingLevelStep )
    }

    static func targetRPMMatches( target: Double, expected: Double ) -> Bool
    {
        target.isFinite && expected.isFinite
            && abs( target - expected ) <= max( 2, expected * 0.001 )
    }

    static func coolingTargetRPM( minimum: Double, maximum: Double, level: Int ) -> Double?
    {
        guard validBounds( minimum: minimum, maximum: maximum ), validCoolingLevel( level )
        else
        {
            return nil
        }
        return minimum + ( maximum - minimum ) * Double( level ) / 100
    }

    static func validConfiguration( _ configuration: FanControlConfiguration ) -> Bool
    {
        switch configuration.mode
        {
            case .system:
                return true
            case .manual:
                return validCoolingLevel( configuration.manualLevel )
            case .curve:
                return validCurves( configuration.curves )
        }
    }

    static func validCurves( _ curves: [ FanControlCurve ] ) -> Bool
    {
        guard ( 1 ... maximumCurveCount ).contains( curves.count ),
              Set( curves.map( \.sensor ) ).count == curves.count
        else
        {
            return false
        }
        return curves.allSatisfy( validCurve )
    }

    static func validCurve( _ curve: FanControlCurve ) -> Bool
    {
        guard ( minimumCurvePointCount ... maximumCurvePointCount ).contains( curve.points.count )
        else
        {
            return false
        }

        for ( index, point ) in curve.points.enumerated()
        {
            guard ( minimumCurveTemperature ... maximumCurveTemperature ).contains( point.temperature ),
                  validCoolingLevel( point.coolingLevel )
            else
            {
                return false
            }

            if index > 0
            {
                let previous = curve.points[ index - 1 ]
                guard point.temperature > previous.temperature,
                      point.coolingLevel >= previous.coolingLevel
                else
                {
                    return false
                }
            }
        }
        return true
    }

    static func nextCurvePoint( for points: [ FanControlCurvePoint ] ) -> FanControlCurvePoint?
    {
        guard points.count < maximumCurvePointCount,
              let first = points.first,
              let last = points.last
        else
        {
            return nil
        }

        var best: ( index: Int, gap: Int )?

        for index in 1 ..< points.count
        {
            let gap = points[ index ].temperature - points[ index - 1 ].temperature

            if gap > 1, gap > ( best?.gap ?? 0 )
            {
                best = ( index, gap )
            }
        }

        if let best
        {
            let lower = points[ best.index - 1 ]
            let upper = points[ best.index ]
            let temperature = lower.temperature + best.gap / 2
            let rawLevel = Double( lower.coolingLevel + upper.coolingLevel ) / 2
            let level = Int( ( rawLevel / Double( coolingLevelStep ) ).rounded() ) * coolingLevelStep
            return FanControlCurvePoint( temperature: temperature, coolingLevel: level )
        }

        if last.temperature < maximumCurveTemperature
        {
            return FanControlCurvePoint(
                temperature: min( maximumCurveTemperature, last.temperature + 10 ),
                coolingLevel: last.coolingLevel
            )
        }

        if first.temperature > minimumCurveTemperature
        {
            return FanControlCurvePoint(
                temperature: max( minimumCurveTemperature, first.temperature - 10 ),
                coolingLevel: first.coolingLevel
            )
        }

        return nil
    }

    static func addingCurvePoint( to points: [ FanControlCurvePoint ] ) -> [ FanControlCurvePoint ]?
    {
        guard let point = nextCurvePoint( for: points )
        else
        {
            return nil
        }

        var updated = points
        updated.append( point )
        updated.sort { $0.temperature < $1.temperature }
        guard validCurve( FanControlCurve( sensor: .hottestSoC, points: updated ) )
        else
        {
            return nil
        }
        return updated
    }

    static func displayName( for source: FanControlTemperatureSource ) -> String
    {
        switch source
        {
            case .averageSoC: return "Average SoC"
            case .hottestSoC: return "Hottest SoC"
            case .averageCPU: return "Average CPU"
            case .hottestCPU: return "Hottest CPU"
            case .hottestGPU: return "Hottest GPU"
        }
    }

    static func curveCoolingLevel(
        curves: [ FanControlCurve ],
        temperatures: [ FanControlTemperatureReading ],
        previousLevel: Int? = nil
    ) -> Int?
    {
        guard let requested = evaluatedCurveCoolingLevel( curves: curves, temperatures: temperatures )
        else
        {
            return nil
        }
        guard let previousLevel, requested < previousLevel
        else
        {
            return requested
        }

        let warmer = temperatures.map
        {
            FanControlTemperatureReading( source: $0.source, celsius: $0.celsius + curveHysteresis )
        }
        guard let held = evaluatedCurveCoolingLevel( curves: curves, temperatures: warmer )
        else
        {
            return nil
        }
        return min( previousLevel, max( requested, held ) )
    }

    private static func evaluatedCurveCoolingLevel(
        curves: [ FanControlCurve ],
        temperatures: [ FanControlTemperatureReading ]
    ) -> Int?
    {
        guard validCurves( curves )
        else
        {
            return nil
        }

        let values = Dictionary( temperatures.map { ( $0.source, $0.celsius ) }, uniquingKeysWith: { _, newest in newest } )
        var levels: [ Int ] = []

        for curve in curves
        {
            guard let temperature = values[ curve.sensor ], validTemperature( temperature )
            else
            {
                return nil
            }
            levels.append( interpolatedCoolingLevel( points: curve.points, temperature: temperature ) )
        }
        return levels.max()
    }

    static func interpolatedCoolingLevel( points: [ FanControlCurvePoint ], temperature: Double ) -> Int
    {
        guard let first = points.first, let last = points.last
        else
        {
            return minimumCoolingLevel
        }

        if temperature <= Double( first.temperature )
        {
            return first.coolingLevel
        }
        if temperature >= Double( last.temperature )
        {
            return last.coolingLevel
        }

        for index in 1 ..< points.count
        {
            let upper = points[ index ]
            guard temperature <= Double( upper.temperature )
            else
            {
                continue
            }
            let lower = points[ index - 1 ]
            let progress = ( temperature - Double( lower.temperature ) )
                / Double( upper.temperature - lower.temperature )
            let raw = Double( lower.coolingLevel )
                + Double( upper.coolingLevel - lower.coolingLevel ) * progress
            let stepped = Int( ceil( raw / Double( coolingLevelStep ) - 1e-9 ) ) * coolingLevelStep
            return min( maximumCoolingLevel, max( minimumCoolingLevel, stepped ) )
        }
        return last.coolingLevel
    }

    static func validTemperature( _ value: Double ) -> Bool
    {
        value.isFinite && value >= 1 && value < 125
    }

    static func aggregatedTemperatures(
        cpuReadings: [ ( key: String, value: Double ) ],
        gpuReadings: [ Double ]
    ) -> [ FanControlTemperatureReading ]
    {
        let cpu = cpuReadings.map( \.value ).filter( validTemperature )
        let gpu = gpuReadings.filter( validTemperature )
        let soc = cpu + gpu
        var readings: [ FanControlTemperatureReading ] = []

        if soc.isEmpty == false
        {
            readings.append( .init( source: .averageSoC, celsius: soc.reduce( 0, + ) / Double( soc.count ) ) )
            if let hottest = soc.max()
            {
                readings.append( .init( source: .hottestSoC, celsius: hottest ) )
            }
        }
        if cpu.isEmpty == false
        {
            readings.append( .init( source: .averageCPU, celsius: cpu.reduce( 0, + ) / Double( cpu.count ) ) )
            if let hottest = cpu.max()
            {
                readings.append( .init( source: .hottestCPU, celsius: hottest ) )
            }
        }
        if let hottest = gpu.max()
        {
            readings.append( .init( source: .hottestGPU, celsius: hottest ) )
        }
        return readings
    }

    static func restoreReason(
        now: Date,
        endsAt: Date?,
        heartbeatAge: TimeInterval,
        verificationFailures: Int,
        temperatureFailures: Int = 0,
        thermalState: ProcessInfo.ThermalState
    ) -> FanControlStopReason?
    {
        if let endsAt, now >= endsAt
        {
            return .timeLimit
        }
        if heartbeatAge > heartbeatLimit
        {
            return .heartbeatLost
        }
        if verificationFailures >= verificationFailureLimit
        {
            return .hardwareChanged
        }
        if temperatureFailures >= temperatureFailureLimit
        {
            return .temperatureUnavailable
        }
        if thermalState == .serious || thermalState == .critical
        {
            return .thermalPressure
        }
        return nil
    }
}
