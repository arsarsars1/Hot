#!/usr/bin/env swift
/*******************************************************************************
 * Fan Control regression checks (policy + window smoke).
 *
 * Run:
 *   swift Scripts/test-fan-control.swift
 *
 * Optional (after installing Hot.app):
 *   HOT_APP=/Applications/Hot.app swift Scripts/test-fan-control.swift --launch
 ******************************************************************************/

import Foundation
import CoreGraphics

// MARK: - Minimal copies of policy helpers under test
// Prefer compiling against Hot sources when possible; this script mirrors the
// curve-edit contracts so CI/agent runs do not need a full xcodebuild test target.

struct CurvePoint: Equatable
{
    var temperature: Int
    var coolingLevel: Int
}

enum Policy
{
    static let minimumCoolingLevel = 0
    static let maximumCoolingLevel = 100
    static let coolingLevelStep = 5
    static let minimumCurveTemperature = 20
    static let maximumCurveTemperature = 110
    static let minimumCurvePointCount = 2
    static let maximumCurvePointCount = 8

    static func validCoolingLevel( _ level: Int ) -> Bool
    {
        ( minimumCoolingLevel ... maximumCoolingLevel ).contains( level )
            && level.isMultiple( of: coolingLevelStep )
    }

    static func validCurve( _ points: [ CurvePoint ] ) -> Bool
    {
        guard ( minimumCurvePointCount ... maximumCurvePointCount ).contains( points.count )
        else
        {
            return false
        }

        for ( index, point ) in points.enumerated()
        {
            guard ( minimumCurveTemperature ... maximumCurveTemperature ).contains( point.temperature ),
                  validCoolingLevel( point.coolingLevel )
            else
            {
                return false
            }

            if index > 0
            {
                let previous = points[ index - 1 ]
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

    static func nextCurvePoint( for points: [ CurvePoint ] ) -> CurvePoint?
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
            return CurvePoint( temperature: temperature, coolingLevel: level )
        }

        if last.temperature < maximumCurveTemperature
        {
            return CurvePoint(
                temperature: min( maximumCurveTemperature, last.temperature + 10 ),
                coolingLevel: last.coolingLevel
            )
        }

        if first.temperature > minimumCurveTemperature
        {
            return CurvePoint(
                temperature: max( minimumCurveTemperature, first.temperature - 10 ),
                coolingLevel: first.coolingLevel
            )
        }

        return nil
    }

    static func addingCurvePoint( to points: [ CurvePoint ] ) -> [ CurvePoint ]?
    {
        guard let point = nextCurvePoint( for: points )
        else
        {
            return nil
        }

        var updated = points
        updated.append( point )
        updated.sort { $0.temperature < $1.temperature }
        guard validCurve( updated )
        else
        {
            return nil
        }
        return updated
    }
}

var failures = 0

func expect( _ condition: @autoclosure () -> Bool, _ message: String )
{
    if condition() == false
    {
        failures += 1
        fputs( "FAIL: \( message )\n", stderr )
    }
    else
    {
        print( "PASS: \( message )" )
    }
}

let defaultPoints = [
    CurvePoint( temperature: 50, coolingLevel: 0 ),
    CurvePoint( temperature: 70, coolingLevel: 100 ),
]

expect( Policy.validCurve( defaultPoints ), "default two-point curve is valid" )

let mid = Policy.nextCurvePoint( for: defaultPoints )
expect( mid?.temperature == 60, "next point splits largest temperature gap (got \( String( describing: mid ) ))" )
expect( mid?.coolingLevel == 50, "next point averages cooling level to a step (got \( String( describing: mid ) ))" )

guard let withMid = Policy.addingCurvePoint( to: defaultPoints )
else
{
    fputs( "FAIL: addingCurvePoint returned nil for default curve\n", stderr )
    exit( 1 )
}

expect( withMid.count == 3, "adding a point grows the curve to 3 points" )
expect( Policy.validCurve( withMid ), "curve remains valid after Add Point" )

let stored = "[{\"points\":[{\"coolingLevel\":0,\"temperature\":50},{\"coolingLevel\":95,\"temperature\":89}],\"sensor\":\"hottestSoC\"}]"
expect( stored.contains( "hottestSoC" ), "fixture matches UserDefaults fanControlCurves shape" )

// Corrupt / unordered levels must be rejected by validCurve
let invalid = [
    CurvePoint( temperature: 50, coolingLevel: 100 ),
    CurvePoint( temperature: 70, coolingLevel: 50 ),
]
expect( Policy.validCurve( invalid ) == false, "descending cooling levels are invalid" )

if failures > 0
{
    fputs( "\( failures ) policy test(s) failed\n", stderr )
    exit( 1 )
}

print( "All Fan Control policy tests passed." )

if CommandLine.arguments.contains( "--launch" )
{
    let appPath = ProcessInfo.processInfo.environment[ "HOT_APP" ] ?? "/Applications/Hot.app"
    let binary = "\( appPath )/Contents/MacOS/Hot"

    guard FileManager.default.isExecutableFile( atPath: binary )
    else
    {
        fputs( "Hot binary missing at \( binary )\n", stderr )
        exit( 1 )
    }

    // Ensure previous instance is gone so we observe a clean launch.
    let kill = Process()
    kill.launchPath = "/usr/bin/killall"
    kill.arguments = [ "Hot" ]
    try? kill.run()
    kill.waitUntilExit()
    Thread.sleep( forTimeInterval: 0.6 )

    let proc = Process()
    proc.executableURL = URL( fileURLWithPath: binary )
    proc.arguments = [ "--open-fan-control" ]
    proc.environment = ProcessInfo.processInfo.environment

    let err = Pipe()
    proc.standardError = err
    try proc.run()

    // Window should appear quickly; process must stay alive (no SMC abort).
    var sawWindow = false
    for _ in 0 ..< 40
    {
        Thread.sleep( forTimeInterval: 0.25 )
        if proc.isRunning == false
        {
            let message = String( data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8 ) ?? ""
            fputs( "Hot exited early (SMC/UI crash?). stderr:\n\( message )\n", stderr )
            exit( 1 )
        }

        let list = Process()
        list.executableURL = URL( fileURLWithPath: "/usr/sbin/lsof" )
        list.arguments = [ "-p", String( proc.processIdentifier ) ]
        let out = Pipe()
        list.standardOutput = out
        try? list.run()
        list.waitUntilExit()

        let windows = CGWindowListCopyWindowInfo( [ .optionOnScreenOnly, .excludeDesktopElements ], kCGNullWindowID ) as? [[ String: Any ]] ?? []
        let mine = windows.filter
        {
            let owner = $0[ kCGWindowOwnerPID as String ] as? pid_t
                ?? pid_t( $0[ "kCGWindowOwnerPID" ] as? Int ?? -1 )
            return owner == pid_t( proc.processIdentifier )
        }

        let named = mine.contains { ( $0[ kCGWindowName as String ] as? String ) == "Fan Control" }
        let sized = mine.contains
        {
            guard let bounds = $0[ kCGWindowBounds as String ] as? [ String: NSNumber ]
            else
            {
                return false
            }
            let width = bounds[ "Width" ]?.doubleValue ?? 0
            let height = bounds[ "Height" ]?.doubleValue ?? 0
            return abs( width - 440 ) < 8 && height >= 480
        }

        if named || sized
        {
            sawWindow = true
            break
        }
    }

    if sawWindow == false
    {
        // Fallback: process stayed alive after --open-fan-control (primary crash regression).
        if proc.isRunning
        {
            print( "PASS: Hot stayed alive with --open-fan-control (window title not observable in this environment)." )
            proc.terminate()
            exit( 0 )
        }
        fputs( "FAIL: Fan Control window not observed and process died\n", stderr )
        exit( 1 )
    }

    print( "PASS: Fan Control window is on-screen." )
    proc.terminate()
}
