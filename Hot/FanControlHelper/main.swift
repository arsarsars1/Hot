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
import os

private let log = Logger( subsystem: FanControlIdentifiers.helperID, category: "FanControl" )

private final class FanControlOwnership
{
    private let lockPath = "/var/run/hot-fan-control.lock"
    private let markerPath = "/var/run/hot-fan-control.active"
    private var lockFile: Int32 = -1

    var isHeld: Bool { lockFile >= 0 }

    func acquire() -> Bool
    {
        if isHeld
        {
            return true
        }

        let descriptor = Darwin.open( lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t( 0o600 ) )
        guard descriptor >= 0, secureRegularFile( descriptor )
        else
        {
            if descriptor >= 0
            {
                Darwin.close( descriptor )
            }
            return false
        }

        guard flock( descriptor, LOCK_EX | LOCK_NB ) == 0
        else
        {
            Darwin.close( descriptor )
            return false
        }

        lockFile = descriptor
        return true
    }

    func release()
    {
        guard isHeld
        else
        {
            return
        }
        _ = flock( lockFile, LOCK_UN )
        Darwin.close( lockFile )
        lockFile = -1
    }

    func markerExists() -> Bool
    {
        var info = stat()
        guard lstat( markerPath, &info ) == 0
        else
        {
            return false
        }
        return info.st_uid == 0
            && ( info.st_mode & S_IFMT ) == S_IFREG
            && ( info.st_mode & mode_t( 0o077 ) ) == 0
            && info.st_nlink == 1
    }

    func createMarker() -> Bool
    {
        guard isHeld, markerExists() == false
        else
        {
            return false
        }

        let descriptor = Darwin.open(
            markerPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t( 0o600 )
        )
        guard descriptor >= 0, secureRegularFile( descriptor )
        else
        {
            if descriptor >= 0
            {
                Darwin.close( descriptor )
            }
            return false
        }

        let marker = Array( "v1\n".utf8 )
        let written = marker.withUnsafeBytes
        {
            Darwin.write( descriptor, $0.baseAddress, $0.count )
        }
        let synced = fsync( descriptor ) == 0
        Darwin.close( descriptor )

        if written != marker.count || synced == false
        {
            _ = unlink( markerPath )
            return false
        }
        return true
    }

    func removeMarker() -> Bool
    {
        markerExists() == false || unlink( markerPath ) == 0
    }

    private func secureRegularFile( _ descriptor: Int32 ) -> Bool
    {
        var info = stat()
        guard fstat( descriptor, &info ) == 0
        else
        {
            return false
        }
        return info.st_uid == 0
            && ( info.st_mode & S_IFMT ) == S_IFREG
            && ( info.st_mode & mode_t( 0o077 ) ) == 0
            && info.st_nlink == 1
    }

    deinit
    {
        release()
    }
}

private final class FanControlController
{
    private let queue = DispatchQueue( label: "com.xs-labs.Hot.fan-control.helper" )
    private let ownership = FanControlOwnership()
    private var hardware: FanControlHardware?
    private var owner: UUID?
    private var isCooling = false
    private var endsAt: Date?
    private var lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
    private var verificationFailures = 0
    private var temperatureFailures = 0
    private var lastStopReason: FanControlStopReason?
    private var coolingLevel: Int?
    private var activeConfiguration: FanControlConfiguration?
    private var connectionCount = 0
    private var timer: DispatchSourceTimer?

    init()
    {
        queue.async
        {
            [ weak self ] in
            self?.recoverAbandonedControlIfNeeded()
        }
    }

    func connectionOpened()
    {
        queue.async
        {
            self.connectionCount += 1
        }
    }

    func connectionClosed( _ id: UUID )
    {
        queue.async
        {
            self.connectionCount = max( 0, self.connectionCount - 1 )
            if self.owner == id, self.isCooling
            {
                _ = self.performRestore( reason: .appDisconnected )
            }
        }
    }

    func status( reply: @escaping ( Data ) -> Void )
    {
        queue.async
        {
            reply( FanControlIPC.encode( self.statusResponse() ) )
        }
    }

    func apply( session id: UUID, encodedConfiguration: Data, reply: @escaping ( Data ) -> Void )
    {
        queue.async
        {
            guard let configuration = FanControlIPC.decodeConfiguration( encodedConfiguration )
            else
            {
                reply( FanControlIPC.encode( .failure( .controlFailed, snapshot: self.currentSnapshot() ) ) )
                return
            }
            reply( FanControlIPC.encode( self.applyConfiguration( session: id, configuration: configuration ) ) )
        }
    }

    func heartbeat( session id: UUID, reply: @escaping ( Data ) -> Void )
    {
        queue.async
        {
            guard self.owner == id, self.isCooling
            else
            {
                reply( FanControlIPC.encode( self.statusResponse() ) )
                return
            }

            self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime

            if let configuration = self.activeConfiguration, configuration.mode == .curve
            {
                self.tickCurve( configuration )
            }
            else if self.hardware?.coolingIsIntact() != true
            {
                self.verificationFailures += 1
            }
            else
            {
                self.verificationFailures = 0
            }

            if let reason = FanControlPolicy.restoreReason(
                now: Date(),
                endsAt: self.endsAt,
                heartbeatAge: 0,
                verificationFailures: self.verificationFailures,
                temperatureFailures: self.temperatureFailures,
                thermalState: ProcessInfo.processInfo.thermalState
            )
            {
                _ = self.performRestore( reason: reason )
            }

            reply( FanControlIPC.encode( self.statusResponse() ) )
        }
    }

    func restore( session id: UUID, reply: @escaping ( Data ) -> Void )
    {
        queue.async
        {
            if self.owner == nil || self.owner == id
            {
                _ = self.performRestore( reason: .recovery )
            }
            reply( FanControlIPC.encode( self.statusResponse() ) )
        }
    }

    private func applyConfiguration( session id: UUID, configuration: FanControlConfiguration ) -> FanControlResponse
    {
        switch configuration.mode
        {
            case .system:
                _ = performRestore( reason: .recovery )
                return statusResponse()

            case .manual:
                return startManual( session: id, level: configuration.manualLevel, configuration: configuration )

            case .curve:
                return startCurve( session: id, configuration: configuration )
        }
    }

    private func startManual( session id: UUID, level: Int, configuration: FanControlConfiguration ) -> FanControlResponse
    {
        do
        {
            try prepareSession( id )
            let hardware = try requireHardware()

            if isCooling, owner == id
            {
                log.info( "manual_update session=\( id.uuidString, privacy: .public ) level=\( level )" )
                let readings = try hardware.updateCooling( level: level )
                beginCooling( session: id, level: level, configuration: configuration, readings: readings )
                return statusResponse()
            }

            try hardware.validateAutomaticControl()
            let readings = try hardware.startCooling( level: level )
            beginCooling( session: id, level: level, configuration: configuration, readings: readings )
            return statusResponse()
        }
        catch let error as FanControlHardwareError
        {
            log.error( "manual_failed session=\( id.uuidString, privacy: .public ) error=\( String( describing: error ), privacy: .public )" )
            return .failure( map( error ), snapshot: currentSnapshot() )
        }
        catch
        {
            log.error( "manual_failed session=\( id.uuidString, privacy: .public ) unexpected" )
            return .failure( .controlFailed, snapshot: currentSnapshot() )
        }
    }

    private func startCurve( session id: UUID, configuration: FanControlConfiguration ) -> FanControlResponse
    {
        do
        {
            try prepareSession( id )
            let hardware = try requireHardware()
            let temperatures = hardware.readTemperatures()
            guard let level = FanControlPolicy.curveCoolingLevel( curves: configuration.curves, temperatures: temperatures )
            else
            {
                log.error( "curve_failed no_level session=\( id.uuidString, privacy: .public )" )
                return .failure( .controlFailed, snapshot: currentSnapshot() )
            }

            if isCooling, owner == id
            {
                log.info( "curve_update session=\( id.uuidString, privacy: .public ) level=\( level ) curves=\( configuration.curves.count )" )
                let readings = try hardware.updateCooling( level: level )
                beginCooling( session: id, level: level, configuration: configuration, readings: readings )
                return statusResponse()
            }

            try hardware.validateAutomaticControl()
            log.info( "curve_start session=\( id.uuidString, privacy: .public ) level=\( level ) curves=\( configuration.curves.count )" )
            let readings = try hardware.startCooling( level: level )
            beginCooling( session: id, level: level, configuration: configuration, readings: readings )
            return statusResponse()
        }
        catch let error as FanControlHardwareError
        {
            log.error( "curve_failed session=\( id.uuidString, privacy: .public ) error=\( String( describing: error ), privacy: .public )" )
            return .failure( map( error ), snapshot: currentSnapshot() )
        }
        catch
        {
            log.error( "curve_failed session=\( id.uuidString, privacy: .public ) unexpected" )
            return .failure( .controlFailed, snapshot: currentSnapshot() )
        }
    }

    private func tickCurve( _ configuration: FanControlConfiguration )
    {
        guard let hardware
        else
        {
            temperatureFailures += 1
            return
        }

        let temperatures = hardware.readTemperatures()
        guard let level = FanControlPolicy.curveCoolingLevel(
            curves: configuration.curves,
            temperatures: temperatures,
            previousLevel: coolingLevel
        )
        else
        {
            temperatureFailures += 1
            return
        }

        temperatureFailures = 0

        if level != coolingLevel
        {
            do
            {
                _ = try hardware.updateCooling( level: level )
                coolingLevel = level
                verificationFailures = 0
            }
            catch
            {
                verificationFailures += 1
            }
        }
        else if hardware.coolingIsIntact()
        {
            verificationFailures = 0
        }
        else
        {
            verificationFailures += 1
        }
    }

    private func prepareSession( _ id: UUID ) throws
    {
        guard ownership.acquire()
        else
        {
            throw FanControlHardwareError.operationFailed
        }
        if owner != nil, owner != id, isCooling
        {
            _ = performRestore( reason: .recovery )
        }
        owner = id
    }

    private func beginCooling(
        session id: UUID,
        level: Int,
        configuration: FanControlConfiguration,
        readings: [ FanControlFanReading ]
    )
    {
        _ = readings
        owner = id
        isCooling = true
        coolingLevel = level
        activeConfiguration = configuration
        endsAt = nil
        lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
        verificationFailures = 0
        temperatureFailures = 0
        lastStopReason = nil
        if ownership.markerExists() == false
        {
            _ = ownership.createMarker()
        }
        startTimer()
    }

    @discardableResult
    private func performRestore( reason: FanControlStopReason ) -> Bool
    {
        let restored = hardware?.restoreAutomatic() ?? FanControlHardware()?.restoreAutomatic() ?? false
        isCooling = false
        coolingLevel = nil
        activeConfiguration = nil
        endsAt = nil
        lastStopReason = reason
        verificationFailures = 0
        temperatureFailures = 0
        if restored
        {
            _ = ownership.removeMarker()
            ownership.release()
            stopTimer()
        }
        return restored
    }

    private func recoverAbandonedControlIfNeeded()
    {
        guard ownership.markerExists()
        else
        {
            return
        }
        guard ownership.acquire()
        else
        {
            return
        }
        _ = performRestore( reason: .recovery )
    }

    private func requireHardware() throws -> FanControlHardware
    {
        if let hardware
        {
            return hardware
        }
        guard let created = FanControlHardware()
        else
        {
            throw FanControlHardwareError.unsupported
        }
        hardware = created
        return created
    }

    private func currentSnapshot() -> FanControlSnapshot
    {
        ( try? hardware?.snapshot(
            isCooling: isCooling,
            endsAt: endsAt,
            stopReason: lastStopReason,
            coolingLevel: coolingLevel,
            configuration: activeConfiguration
        ) ) ?? .empty
    }

    private func statusResponse() -> FanControlResponse
    {
        .success( currentSnapshot() )
    }

    private func map( _ error: FanControlHardwareError ) -> FanControlErrorCode
    {
        switch error
        {
            case .noFans: return .noFans
            case .unsupported: return .unsupportedHardware
            case .alreadyControlled: return .alreadyControlled
            case .operationFailed: return .controlFailed
        }
    }

    private func startTimer()
    {
        guard timer == nil
        else
        {
            return
        }

        let timer = DispatchSource.makeTimerSource( queue: queue )
        timer.schedule( deadline: .now() + 1, repeating: 1 )
        timer.setEventHandler
        {
            [ weak self ] in
            guard let self, self.isCooling
            else
            {
                return
            }

            let age = ProcessInfo.processInfo.systemUptime - self.lastHeartbeatUptime
            if let reason = FanControlPolicy.restoreReason(
                now: Date(),
                endsAt: self.endsAt,
                heartbeatAge: age,
                verificationFailures: self.verificationFailures,
                temperatureFailures: self.temperatureFailures,
                thermalState: ProcessInfo.processInfo.thermalState
            )
            {
                _ = self.performRestore( reason: reason )
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer()
    {
        timer?.cancel()
        timer = nil
    }
}

private final class FanControlListenerDelegate: NSObject, NSXPCListenerDelegate
{
    private let controller = FanControlController()
    private var sessions: [ NSXPCConnection: UUID ] = [:]

    func listener( _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection ) -> Bool
    {
        newConnection.exportedInterface = NSXPCInterface( with: FanControlXPCProtocol.self )
        let session = UUID()
        let exported = FanControlExported( controller: controller, session: session )
        newConnection.exportedObject = exported
        newConnection.setCodeSigningRequirement( FanControlIdentifiers.appCodeRequirement )
        newConnection.invalidationHandler =
        {
            [ weak self ] in
            self?.controller.connectionClosed( session )
            self?.sessions[ newConnection ] = nil
        }
        sessions[ newConnection ] = session
        controller.connectionOpened()
        newConnection.resume()
        return true
    }
}

private final class FanControlExported: NSObject, FanControlXPCProtocol
{
    private let controller: FanControlController
    private let session: UUID

    init( controller: FanControlController, session: UUID )
    {
        self.controller = controller
        self.session = session
    }

    func status( withReply reply: @escaping ( Data ) -> Void )
    {
        controller.status( reply: reply )
    }

    func startMaximumCooling( withReply reply: @escaping ( Data ) -> Void )
    {
        let configuration = FanControlConfiguration.manual( level: FanControlPolicy.maximumCoolingLevel )
        guard let data = FanControlIPC.encode( configuration )
        else
        {
            reply( FanControlIPC.encode( .failure( .controlFailed ) ) )
            return
        }
        controller.apply( session: session, encodedConfiguration: data, reply: reply )
    }

    func applyConfiguration( _ configuration: Data, withReply reply: @escaping ( Data ) -> Void )
    {
        controller.apply( session: session, encodedConfiguration: configuration, reply: reply )
    }

    func heartbeat( withReply reply: @escaping ( Data ) -> Void )
    {
        controller.heartbeat( session: session, reply: reply )
    }

    func restoreAutomatic( withReply reply: @escaping ( Data ) -> Void )
    {
        controller.restore( session: session, reply: reply )
    }
}

private func runSelfTest() -> Int32
{
    guard FanControlHardware() != nil
    else
    {
        fputs( "selftest: SMC unavailable (ok on fanless CI)\n", stderr )
        return 0
    }
    fputs( "selftest: ok\n", stderr )
    return 0
}

private func main() -> Int32
{
    if CommandLine.arguments.contains( "--selftest" )
    {
        return runSelfTest()
    }

    guard geteuid() == 0
    else
    {
        fputs( "Fan control helper must run as root\n", stderr )
        return 1
    }

    let delegate = FanControlListenerDelegate()
    let listener = NSXPCListener( machServiceName: FanControlIdentifiers.helperID )
    listener.delegate = delegate
    listener.resume()
    log.info( "Fan control helper listening" )
    RunLoop.main.run()
    return 0
}

exit( main() )
