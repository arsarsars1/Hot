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

enum FanControlHardwareError: Error
{
    case noFans
    case unsupported
    case alreadyControlled
    case operationFailed
}

final class FanControlHardware
{
    private struct Fan
    {
        let index: Int
        let actual: SMCKeyDescriptor
        let minimum: SMCKeyDescriptor
        let maximum: SMCKeyDescriptor
        let target: SMCKeyDescriptor
        let mode: SMCKeyDescriptor
        let minimumRPM: Double
        let maximumRPM: Double
    }

    private let client: SMCClient
    private var controlledFans: [ Fan ]?
    private var cachedForceTestKey: SMCKeyDescriptor?
    private var didDiscoverForceTestKey = false
    private var activeTargets: [ Double ] = []
    private var cachedTemperatureKeys: [ SMCKeyDescriptor ]?

    init?()
    {
        guard let client = try? SMCClient()
        else
        {
            return nil
        }
        self.client = client
    }

    static let hasControllableFan: Bool =
    {
        guard let hardware = FanControlHardware()
        else
        {
            return false
        }
        return ( try? hardware.discoverControlledFans() )?.isEmpty == false
    }()

    func readOnlySnapshot() throws -> FanControlSnapshot
    {
        let fans = try discoverControlledFans()
        let snapshot = FanControlSnapshot(
            fans: try readings( for: fans ),
            isCooling: false,
            endsAt: nil,
            stopReason: nil,
            coolingLevel: nil,
            configuration: nil,
            temperatures: readTemperatures()
        )

        if let forceTest = forceTestKey(), try byteValue( forceTest ) != 0
        {
            throw FanControlHardwareError.alreadyControlled
        }
        return snapshot
    }

    func startCooling( level: Int ) throws -> [ FanControlFanReading ]
    {
        let fans = try discoverControlledFans()
        guard try fans.allSatisfy( { try FanControlPolicy.isAutomaticMode( modeValue( $0.mode ) ) } )
        else
        {
            throw FanControlHardwareError.alreadyControlled
        }
        if let forceTest = forceTestKey(), try byteValue( forceTest ) != 0
        {
            throw FanControlHardwareError.alreadyControlled
        }

        let targets = try fans.map
        {
            fan -> Double in
            guard let target = FanControlPolicy.coolingTargetRPM(
                minimum: fan.minimumRPM,
                maximum: fan.maximumRPM,
                level: level
            )
            else
            {
                throw FanControlHardwareError.operationFailed
            }
            return target
        }

        var directSucceeded = true
        for ( fan, target ) in zip( fans, targets )
        {
            if writeManualPair( for: fan, target: target ) == false
            {
                directSucceeded = false
            }
        }

        if directSucceeded
        {
            Thread.sleep( forTimeInterval: 0.25 )
            directSucceeded = fans.allSatisfy { ( try? modeValue( $0.mode ) ) == 1 }
        }

        if directSucceeded == false
        {
            guard let forceTest = forceTestKey(), setByte( 1, for: forceTest, attempts: 20 )
            else
            {
                throw FanControlHardwareError.operationFailed
            }

            for fan in fans
            {
                guard setValue( fan.maximumRPM, for: fan.target, attempts: 10 )
                else
                {
                    throw FanControlHardwareError.operationFailed
                }
            }

            Thread.sleep( forTimeInterval: 3 )

            for fan in fans
            {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                guard setMode( 1, for: fan, untilUptime: deadline )
                else
                {
                    throw FanControlHardwareError.operationFailed
                }
            }

            for ( fan, target ) in zip( fans, targets )
            {
                guard setTargetRPM( target, for: fan, attempts: 10 )
                else
                {
                    throw FanControlHardwareError.operationFailed
                }
            }
        }

        guard verifyCooling( fans, targets: targets, attempts: 10 )
        else
        {
            throw FanControlHardwareError.operationFailed
        }

        activeTargets = targets
        return try readings( for: fans )
    }

    func updateCooling( level: Int ) throws -> [ FanControlFanReading ]
    {
        let fans = try discoverControlledFans()
        guard FanControlPolicy.validCoolingLevel( level )
        else
        {
            throw FanControlHardwareError.operationFailed
        }

        let targets = try fans.map
        {
            fan -> Double in
            guard let target = FanControlPolicy.coolingTargetRPM(
                minimum: fan.minimumRPM,
                maximum: fan.maximumRPM,
                level: level
            )
            else
            {
                throw FanControlHardwareError.operationFailed
            }
            return target
        }

        for ( fan, target ) in zip( fans, targets )
        {
            guard setTargetRPM( target, for: fan, attempts: 10 )
            else
            {
                throw FanControlHardwareError.operationFailed
            }
        }

        guard verifyCooling( fans, targets: targets, attempts: 10 )
        else
        {
            throw FanControlHardwareError.operationFailed
        }

        activeTargets = targets
        return try readings( for: fans )
    }

    func validateAutomaticControl() throws
    {
        let fans = try discoverControlledFans()
        guard try fans.allSatisfy( { try FanControlPolicy.isAutomaticMode( modeValue( $0.mode ) ) } )
        else
        {
            throw FanControlHardwareError.alreadyControlled
        }
        if let forceTest = forceTestKey()
        {
            guard try byteValue( forceTest ) == 0
            else
            {
                throw FanControlHardwareError.alreadyControlled
            }
        }
    }

    @discardableResult
    func restoreAutomatic() -> Bool
    {
        guard let fans = try? discoverControlledFans()
        else
        {
            return false
        }

        for fan in fans
        {
            _ = setMode( 0, for: fan, attempts: 20 )
            _ = setValue( 0, for: fan.target, attempts: 10 )
        }

        if let forceTest = forceTestKey()
        {
            _ = setByte( 0, for: forceTest, attempts: 20 )
        }

        let automatic = fans.allSatisfy
        {
            fan in
            ( try? modeValue( fan.mode ) ).map( FanControlPolicy.isAutomaticMode ) == true
        }
        let forceTestOff = forceTestKey().map { ( try? byteValue( $0 ) ) == 0 } ?? true

        if automatic && forceTestOff
        {
            activeTargets.removeAll()
        }
        return automatic && forceTestOff
    }

    func snapshot(
        isCooling: Bool,
        endsAt: Date?,
        stopReason: FanControlStopReason?,
        coolingLevel: Int? = nil,
        configuration: FanControlConfiguration? = nil
    ) throws -> FanControlSnapshot
    {
        let fans = try discoverControlledFans()
        return FanControlSnapshot(
            fans: try readings( for: fans ),
            isCooling: isCooling,
            endsAt: endsAt,
            stopReason: stopReason,
            coolingLevel: coolingLevel,
            configuration: configuration,
            temperatures: readTemperatures()
        )
    }

    func coolingIsIntact() -> Bool
    {
        guard let fans = try? discoverControlledFans()
        else
        {
            return false
        }
        return verifyCooling( fans, targets: activeTargets )
    }

    func readTemperatures() -> [ FanControlTemperatureReading ]
    {
        let keys: [ SMCKeyDescriptor ]
        if let cachedTemperatureKeys
        {
            keys = cachedTemperatureKeys
        }
        else
        {
            let discovered = ( try? client.keys
            {
                name in
                TemperatureSensorKeys.isCPUTemperatureKey( name ) || TemperatureSensorKeys.isGPUTemperatureKey( name )
            } ) ?? []
            cachedTemperatureKeys = discovered
            keys = discovered
        }

        let cpu = keys.filter { TemperatureSensorKeys.isCPUTemperatureKey( $0.name ) }.compactMap
        {
            key -> ( key: String, value: Double )? in
            guard let value = try? client.readValue( key ),
                  value >= TemperatureSensorKeys.minimumChipTemperature,
                  FanControlPolicy.validTemperature( value )
            else
            {
                return nil
            }
            return ( key.name, value )
        }

        let gpu = keys.filter { TemperatureSensorKeys.isGPUTemperatureKey( $0.name ) }.compactMap
        {
            key -> Double? in
            guard let value = try? client.readValue( key ),
                  value >= TemperatureSensorKeys.minimumChipTemperature,
                  FanControlPolicy.validTemperature( value )
            else
            {
                return nil
            }
            return value
        }

        return FanControlPolicy.aggregatedTemperatures( cpuReadings: cpu, gpuReadings: gpu )
    }

    // MARK: - Discovery

    private func fanCount() throws -> Int
    {
        guard let key = try? client.key( named: "FNum" ),
              let value = try? client.readValue( key )
        else
        {
            throw FanControlHardwareError.noFans
        }
        guard let count = FanControlPolicy.fanCount( from: value )
        else
        {
            throw value == 0 ? FanControlHardwareError.noFans : FanControlHardwareError.unsupported
        }
        return count
    }

    private func discoverControlledFans() throws -> [ Fan ]
    {
        if let controlledFans
        {
            return controlledFans
        }

        let count = try fanCount()
        var fans: [ Fan ] = []

        for index in 0 ..< count
        {
            guard let actual = try? client.key( named: "F\( index )Ac" ),
                  let minimum = try? client.key( named: "F\( index )Mn" ),
                  let maximum = try? client.key( named: "F\( index )Mx" ),
                  let target = try? client.key( named: "F\( index )Tg" ),
                  let mode = modeKey( for: index ),
                  mode.info.dataSize == 1,
                  let minimumRPM = try? client.readValue( minimum ),
                  let maximumRPM = try? client.readValue( maximum ),
                  FanControlPolicy.validBounds( minimum: minimumRPM, maximum: maximumRPM ),
                  SMCValueCodec.encode( maximumRPM, type: target.info.dataType ) != nil
            else
            {
                throw FanControlHardwareError.unsupported
            }

            fans.append(
                Fan(
                    index: index,
                    actual: actual,
                    minimum: minimum,
                    maximum: maximum,
                    target: target,
                    mode: mode,
                    minimumRPM: minimumRPM,
                    maximumRPM: maximumRPM
                )
            )
        }

        controlledFans = fans
        return fans
    }

    private func modeKey( for index: Int ) -> SMCKeyDescriptor?
    {
        for name in [ "F\( index )md", "F\( index )Md" ]
        {
            if let key = try? client.key( named: name ), ( try? client.readBytes( key ) ) != nil
            {
                return key
            }
        }
        return nil
    }

    private func forceTestKey() -> SMCKeyDescriptor?
    {
        if didDiscoverForceTestKey
        {
            return cachedForceTestKey
        }
        didDiscoverForceTestKey = true
        guard let key = try? client.key( named: "Ftst" ), key.info.dataSize == 1
        else
        {
            return nil
        }
        cachedForceTestKey = key
        return key
    }

    // MARK: - Reads / writes

    private func readings( for fans: [ Fan ] ) throws -> [ FanControlFanReading ]
    {
        try fans.map
        {
            fan in
            guard let actual = try? client.readValue( fan.actual ),
                  let minimum = try? client.readValue( fan.minimum ),
                  let maximum = try? client.readValue( fan.maximum ),
                  let target = try? client.readValue( fan.target ),
                  FanControlPolicy.validReading( actual ),
                  FanControlPolicy.validReading( target ),
                  FanControlPolicy.validBounds( minimum: minimum, maximum: maximum )
            else
            {
                throw FanControlHardwareError.operationFailed
            }

            return FanControlFanReading(
                index: fan.index,
                actualRPM: max( 0, actual ),
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: max( 0, target ),
                isManuallyControlled: try FanControlPolicy.isAutomaticMode( modeValue( fan.mode ) ) == false
            )
        }
    }

    private func verifyCooling( _ fans: [ Fan ], targets: [ Double ], attempts: Int = 1 ) -> Bool
    {
        guard fans.count == targets.count
        else
        {
            return false
        }

        for attempt in 0 ..< attempts
        {
            let matches = zip( fans, targets ).allSatisfy
            {
                fan, expected in
                guard ( try? modeValue( fan.mode ) ) == 1,
                      let target = try? client.readValue( fan.target )
                else
                {
                    return false
                }
                return FanControlPolicy.targetRPMMatches( target: target, expected: expected )
            }
            if matches
            {
                return true
            }
            if attempt + 1 < attempts
            {
                Thread.sleep( forTimeInterval: 0.05 )
            }
        }
        return false
    }

    private func modeValue( _ key: SMCKeyDescriptor ) throws -> UInt8
    {
        try byteValue( key )
    }

    private func byteValue( _ key: SMCKeyDescriptor ) throws -> UInt8
    {
        guard let bytes = try? client.readBytes( key ), bytes.count == 1
        else
        {
            throw FanControlHardwareError.operationFailed
        }
        return bytes[ 0 ]
    }

    private func setMode( _ value: UInt8, for fan: Fan, attempts: Int ) -> Bool
    {
        guard setByte( value, for: fan.mode, attempts: attempts )
        else
        {
            return false
        }
        return ( try? modeValue( fan.mode ) ) == value
    }

    private func setMode( _ value: UInt8, for fan: Fan, untilUptime deadline: TimeInterval ) -> Bool
    {
        repeat
        {
            if setMode( value, for: fan, attempts: 1 )
            {
                return true
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0
            {
                return false
            }
            Thread.sleep( forTimeInterval: min( 0.1, remaining ) )
        }
        while ProcessInfo.processInfo.systemUptime < deadline

        return false
    }

    private func setTargetRPM( _ target: Double, for fan: Fan, attempts: Int ) -> Bool
    {
        for attempt in 0 ..< attempts
        {
            _ = writeManualPair( for: fan, target: target )
            if let currentTarget = try? client.readValue( fan.target ),
               FanControlPolicy.targetRPMMatches( target: currentTarget, expected: target ),
               ( try? modeValue( fan.mode ) ) == 1
            {
                return true
            }
            if attempt + 1 < attempts
            {
                Thread.sleep( forTimeInterval: 0.05 )
            }
        }
        return false
    }

    private func writeManualPair( for fan: Fan, target: Double ) -> Bool
    {
        _ = try? client.writeBytes( fan.mode, data: Data( [ 1 ] ) )
        do
        {
            try client.writeValue( fan.target, value: target )
            return true
        }
        catch
        {
            return false
        }
    }

    private func setByte( _ value: UInt8, for key: SMCKeyDescriptor, attempts: Int ) -> Bool
    {
        for attempt in 0 ..< attempts
        {
            do
            {
                try client.writeBytes( key, data: Data( [ value ] ) )
                if ( try? byteValue( key ) ) == value
                {
                    return true
                }
            }
            catch
            {}
            if attempt + 1 < attempts
            {
                Thread.sleep( forTimeInterval: 0.05 )
            }
        }
        return false
    }

    private func setValue( _ value: Double, for key: SMCKeyDescriptor, attempts: Int ) -> Bool
    {
        for attempt in 0 ..< attempts
        {
            do
            {
                try client.writeValue( key, value: value )
                return true
            }
            catch
            {}
            if attempt + 1 < attempts
            {
                Thread.sleep( forTimeInterval: 0.05 )
            }
        }
        return false
    }
}
