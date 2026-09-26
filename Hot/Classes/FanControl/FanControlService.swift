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

import AppKit
import Foundation
import Security
import ServiceManagement

extension Notification.Name
{
    static let fanControlDidUpdate = Notification.Name( "HotFanControlDidUpdate" )
}

/// App-side client for the privileged fan-control helper.
final class FanControlService: NSObject
{
    enum AccessState: Equatable
    {
        case unsupportedOS
        case notRegistered
        case requiresApproval
        case enabled
        case unavailable
    }

    static let shared = FanControlService()

    private( set ) var accessState: AccessState = .notRegistered
    private( set ) var snapshot: FanControlSnapshot = .empty
    private( set ) var error: FanControlErrorCode?
    private( set ) var isWorking = false
    /// False for adhoc / wrong-team Debug builds — they cannot use the signed LaunchDaemon.
    private( set ) var clientMeetsCodeRequirement = true

    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var panelVisibleCount = 0
    private var requestInFlight = false
    private var requestGeneration = 0
    private var observingWorkspace = false
    private var workingTimeout: DispatchWorkItem?
    private var pendingCompletions: [ UUID: ( FanControlResponse? ) -> Void ] = [:]
    private var loggedSigningMismatch = false

    private override init()
    {
        super.init()
        self.refreshAccessState()
    }

    deinit
    {
        NSWorkspace.shared.notificationCenter.removeObserver( self )
        self.connection?.invalidate()
        self.timer?.invalidate()
    }

    static var isSupportedOnThisOS: Bool
    {
        if #available( macOS 13.0, * )
        {
            return true
        }

        return false
    }

    static func recoverIfNeeded()
    {
        guard UserDefaults.standard.bool( forKey: FanControlDefaults.recoveryNeeded )
        else
        {
            return
        }

        shared.restoreAutomatic()
    }

    static func restoreBeforeTerminationIfNeeded()
    {
        guard UserDefaults.standard.bool( forKey: FanControlDefaults.recoveryNeeded )
        else
        {
            return
        }

        shared.restoreAutomatic()
    }

    func windowDidAppear()
    {
        self.panelDidAppear()
    }

    func windowDidDisappear()
    {
        self.panelDidDisappear()
    }

    func panelDidAppear()
    {
        self.panelVisibleCount += 1
        self.startObservingSystemState()
        self.refresh()
        self.startTimerIfNeeded()
    }

    func panelDidDisappear()
    {
        self.panelVisibleCount = max( 0, self.panelVisibleCount - 1 )
        self.stopIdleWorkIfPossible()
    }

    func refresh()
    {
        self.refreshAccessState()

        // Never bump request generation while an apply/restore is in flight —
        // that was leaving the UI stuck on "Working…".
        guard self.isWorking == false
        else
        {
            self.postUpdate()
            return
        }

        if self.accessState == .enabled
        {
            self.requestStatus()
        }
        else
        {
            self.refreshLocalProbe()
        }

        self.postUpdate()
    }

    func authorize()
    {
        guard #available( macOS 13.0, * )
        else
        {
            self.accessState = .unsupportedOS
            self.error       = .helperUnavailable
            self.postUpdate()
            return
        }

        self.refreshAccessState()

        guard self.clientMeetsCodeRequirement
        else
        {
            self.error = .helperUnavailable
            self.postUpdate()
            return
        }

        switch self.accessState
        {
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()

            case .enabled:
                self.requestStatus()

            case .unavailable, .unsupportedOS:
                self.error = .helperUnavailable

            case .notRegistered:
                self.beginWorking()

                do
                {
                    try Self.appService.register()
                    UserDefaults.standard.set( Self.helperVersion, forKey: FanControlDefaults.helperVersion )
                    self.refreshAccessState()
                    self.endWorking()

                    if self.accessState == .requiresApproval
                    {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    else if self.accessState == .enabled
                    {
                        self.requestStatus()
                    }
                }
                catch
                {
                    self.endWorking()
                    self.refreshAccessState()

                    if self.accessState == .requiresApproval
                    {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    else
                    {
                        self.error = .helperUnavailable
                    }
                }
        }

        self.startTimerIfNeeded()
        self.postUpdate()
    }

    func applyConfiguration( _ configuration: FanControlConfiguration )
    {
        guard FanControlPolicy.validConfiguration( configuration )
        else
        {
            self.error = .controlFailed
            self.postUpdate()
            return
        }

        if configuration.mode == .system
        {
            self.restoreAutomatic()
            return
        }

        guard self.accessState == .enabled
        else
        {
            self.authorize()
            return
        }

        guard let encoded = FanControlIPC.encode( configuration )
        else
        {
            self.error = .controlFailed
            self.postUpdate()
            return
        }

        self.error = nil
        self.startObservingSystemState()
        let generation = self.beginRequest()
        UserDefaults.standard.set( true, forKey: FanControlDefaults.recoveryNeeded )
        self.beginWorking()
        FanControlDiagnostics.leaveBreadcrumb(
            category: "xpc",
            message: "apply_begin",
            data: [
                "mode": configuration.mode.rawValue,
                "generation": String( generation ),
                "curves": String( configuration.curves.count ),
            ]
        )

        self.send(
            {
                proxy, reply in
                proxy.applyConfiguration( encoded, withReply: reply )
            }
        )
        {
            response in

            let isCurrent = self.finishRequest( generation )
            self.endWorking()

            FanControlDiagnostics.leaveBreadcrumb(
                category: "xpc",
                message: "apply_end",
                data: [
                    "generation": String( generation ),
                    "current": isCurrent ? "1" : "0",
                    "succeeded": response.map { $0.succeeded ? "1" : "0" } ?? "nil",
                    "error": response?.error?.rawValue ?? "",
                    "isCooling": response.map { $0.snapshot.isCooling ? "1" : "0" } ?? "",
                ]
            )

            guard isCurrent
            else
            {
                self.postUpdate()
                return
            }

            guard let response = response
            else
            {
                FanControlDiagnostics.report( "apply_no_response", detail: "XPC reply missing", location: "applyConfiguration" )
                self.error = .helperUnavailable
                self.postUpdate()
                return
            }

            self.apply( response )

            if response.succeeded, response.snapshot.isCooling
            {
                self.startTimerIfNeeded()
            }
            else if !response.succeeded
            {
                self.error = response.error ?? .controlFailed
                FanControlDiagnostics.report(
                    "apply_failed",
                    detail: response.error?.rawValue ?? "controlFailed",
                    location: "applyConfiguration"
                )
            }

            self.postUpdate()
        }
    }

    func restoreAutomatic()
    {
        guard self.accessState == .enabled || UserDefaults.standard.bool( forKey: FanControlDefaults.recoveryNeeded )
        else
        {
            return
        }

        let generation = self.beginRequest()
        self.beginWorking()

        self.send(
            {
                proxy, reply in
                proxy.restoreAutomatic( withReply: reply )
            }
        )
        {
            response in

            let isCurrent = self.finishRequest( generation )
            self.endWorking()

            guard isCurrent
            else
            {
                self.postUpdate()
                return
            }

            if let response = response
            {
                self.apply( response )

                if response.succeeded, response.snapshot.isCooling == false
                {
                    UserDefaults.standard.removeObject( forKey: FanControlDefaults.recoveryNeeded )
                }
            }
            else
            {
                self.error = .helperUnavailable
            }

            self.postUpdate()
        }
    }

    // MARK: - Private

    @available( macOS 13.0, * )
    private static var appService: SMAppService
    {
        SMAppService.daemon( plistName: FanControlIdentifiers.plistName )
    }

    private static var helperVersion: String
    {
        Bundle.main.object( forInfoDictionaryKey: "HotFanControlHelperVersion" ) as? String
            ?? Bundle.main.object( forInfoDictionaryKey: "CFBundleVersion" ) as? String
            ?? "0"
    }

    private func refreshAccessState()
    {
        guard #available( macOS 13.0, * )
        else
        {
            self.accessState = .unsupportedOS
            return
        }

        if Self.evaluateClientCodeRequirement() == false
        {
            self.clientMeetsCodeRequirement = false
            self.accessState = .unavailable
            self.error = .helperUnavailable
            if self.loggedSigningMismatch == false
            {
                self.loggedSigningMismatch = true
                FanControlDiagnostics.report(
                    "client_codesign_mismatch",
                    detail: "Adhoc or wrong-team build cannot use SMAppService / helper XPC. Use signed Hot from /Applications.",
                    location: "refreshAccessState"
                )
            }
            return
        }

        self.clientMeetsCodeRequirement = true

        switch Self.appService.status
        {
            case .enabled:
                self.accessState = .enabled

            case .requiresApproval:
                self.accessState = .requiresApproval

            case .notFound, .notRegistered:
                self.accessState = .notRegistered

            @unknown default:
                self.accessState = .unavailable
        }
    }

    /// Matches the helper’s `setCodeSigningRequirement(appCodeRequirement)`.
    private static func evaluateClientCodeRequirement() -> Bool
    {
        var code: SecCode?
        guard SecCodeCopySelf( [], &code ) == errSecSuccess, let code
        else
        {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode( code, [], &staticCode ) == errSecSuccess, let staticCode
        else
        {
            return false
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation( staticCode, SecCSFlags( rawValue: kSecCSSigningInformation ), &info ) == errSecSuccess,
              let info = info as? [ String: Any ]
        else
        {
            return false
        }

        let team = info[ kSecCodeInfoTeamIdentifier as String ] as? String
        let identifier = info[ kSecCodeInfoIdentifier as String ] as? String
        return team == FanControlIdentifiers.teamID && identifier == FanControlIdentifiers.appBundleID
    }

    private func refreshLocalProbe()
    {
        DispatchQueue.global( qos: .utility ).async
        {
            let probe: FanControlSnapshot

            if let hardware = FanControlHardware()
            {
                probe = ( try? hardware.readOnlySnapshot() ) ?? .empty
            }
            else
            {
                probe = .empty
            }

            DispatchQueue.main.async
            {
                if self.accessState != .enabled
                {
                    self.snapshot = probe
                    self.postUpdate()
                }
            }
        }
    }

    private func requestStatus()
    {
        guard self.isWorking == false, self.requestInFlight == false
        else
        {
            return
        }

        let generation = self.beginRequest()

        self.send(
            {
                proxy, reply in
                proxy.status( withReply: reply )
            }
        )
        {
            response in

            guard self.finishRequest( generation )
            else
            {
                return
            }

            if let response = response
            {
                self.apply( response )
            }
            else
            {
                self.error = .helperUnavailable
            }

            self.postUpdate()
        }
    }

    private func sendHeartbeat()
    {
        self.send(
            {
                proxy, reply in
                proxy.heartbeat( withReply: reply )
            }
        )
        {
            response in

            if let response = response
            {
                self.apply( response )
                self.postUpdate()
            }
        }
    }

    private func apply( _ response: FanControlResponse )
    {
        self.snapshot = response.snapshot
        self.error    = response.succeeded ? nil : ( response.error ?? self.error )

        if response.succeeded, response.snapshot.isCooling == false
        {
            UserDefaults.standard.removeObject( forKey: FanControlDefaults.recoveryNeeded )
        }
    }

    private func beginRequest() -> Int
    {
        self.requestInFlight   = true
        self.requestGeneration += 1
        return self.requestGeneration
    }

    private func finishRequest( _ generation: Int ) -> Bool
    {
        guard generation == self.requestGeneration
        else
        {
            return false
        }

        self.requestInFlight = false
        return true
    }

    private func beginWorking()
    {
        self.isWorking = true
        self.workingTimeout?.cancel()

        let timeout = DispatchWorkItem
        {
            [ weak self ] in
            guard let self = self, self.isWorking
            else
            {
                return
            }

            FanControlDiagnostics.report(
                "apply_timeout",
                detail: "Helper did not reply within 12s",
                location: "beginWorking"
            )
            self.failAllPending( reason: "timeout" )
            self.workingTimeout = nil
            self.isWorking = false
            self.requestInFlight = false
            self.error = .helperUnavailable
            self.postUpdate()
        }
        self.workingTimeout = timeout
        DispatchQueue.main.asyncAfter( deadline: .now() + 12.0, execute: timeout )
        self.postUpdate()
    }

    private func endWorking()
    {
        self.workingTimeout?.cancel()
        self.workingTimeout = nil
        self.isWorking = false
    }

    private func failAllPending( reason: String )
    {
        let pending = self.pendingCompletions
        self.pendingCompletions.removeAll()
        if pending.isEmpty == false
        {
            FanControlDiagnostics.leaveBreadcrumb(
                category: "xpc",
                message: "fail_pending",
                data: [ "reason": reason, "count": String( pending.count ) ]
            )
        }
        for ( _, completion ) in pending
        {
            completion( nil )
        }
    }

    private func send( _ work: @escaping ( FanControlXPCProtocol, @escaping ( Data ) -> Void ) -> Void, completion: @escaping ( FanControlResponse? ) -> Void )
    {
        let token = UUID()
        var finished = false
        let finish: ( FanControlResponse? ) -> Void =
        {
            response in
            guard finished == false
            else
            {
                return
            }
            finished = true
            self.pendingCompletions[ token ] = nil
            completion( response )
        }
        self.pendingCompletions[ token ] = finish

        guard let proxy = self.remoteProxy()
        else
        {
            FanControlDiagnostics.report( "xpc_no_proxy", detail: "Could not create helper proxy", location: "send" )
            finish( nil )
            return
        }

        work( proxy )
        {
            data in

            let response = FanControlIPC.decode( data )
            DispatchQueue.main.async
            {
                finish( response )
            }
        }
    }

    private func remoteProxy() -> FanControlXPCProtocol?
    {
        if self.connection == nil
        {
            let connection = NSXPCConnection( machServiceName: FanControlIdentifiers.helperID, options: .privileged )
            connection.remoteObjectInterface = NSXPCInterface( with: FanControlXPCProtocol.self )

            if #available( macOS 13.0, * )
            {
                connection.setCodeSigningRequirement( FanControlIdentifiers.helperCodeRequirement )
            }

            connection.invalidationHandler =
            {
                [ weak self ] in
                DispatchQueue.main.async
                {
                    guard let self = self
                    else
                    {
                        return
                    }
                    FanControlDiagnostics.leaveBreadcrumb( category: "xpc", message: "connection_invalidated" )
                    self.connection = nil
                    self.failAllPending( reason: "invalidated" )
                    if self.isWorking
                    {
                        self.endWorking()
                        self.requestInFlight = false
                        self.error = .helperUnavailable
                        self.postUpdate()
                    }
                }
            }
            connection.interruptionHandler =
            {
                [ weak self ] in
                DispatchQueue.main.async
                {
                    guard let self = self
                    else
                    {
                        return
                    }
                    FanControlDiagnostics.leaveBreadcrumb( category: "xpc", message: "connection_interrupted" )
                    self.connection = nil
                    self.failAllPending( reason: "interrupted" )
                    if self.isWorking
                    {
                        self.endWorking()
                        self.requestInFlight = false
                        self.error = .helperUnavailable
                        self.postUpdate()
                    }
                }
            }
            connection.resume()
            self.connection = connection
            FanControlDiagnostics.leaveBreadcrumb( category: "xpc", message: "connection_opened" )
        }

        guard let proxy = self.connection?.remoteObjectProxyWithErrorHandler(
            {
                [ weak self ] error in
                DispatchQueue.main.async
                {
                    FanControlDiagnostics.report(
                        "xpc_proxy_error",
                        detail: error.localizedDescription,
                        location: "remoteObjectProxy"
                    )
                    self?.connection = nil
                    self?.failAllPending( reason: "proxy_error" )
                }
            }
        ) as? FanControlXPCProtocol
        else
        {
            return nil
        }

        return proxy
    }

    private func startTimerIfNeeded()
    {
        guard self.timer == nil
        else
        {
            return
        }

        let timer = Timer( timeInterval: 1.0, repeats: true )
        {
            [ weak self ] _ in
            self?.tick()
        }
        RunLoop.main.add( timer, forMode: .common )
        self.timer = timer
    }

    private func stopIdleWorkIfPossible()
    {
        guard self.panelVisibleCount == 0, self.snapshot.isCooling == false, self.isWorking == false
        else
        {
            return
        }

        self.timer?.invalidate()
        self.timer = nil
        self.workingTimeout?.cancel()
        self.workingTimeout = nil
        self.connection?.invalidate()
        self.connection = nil
    }

    private func tick()
    {
        // Heartbeats must continue while Apply is in flight — otherwise the helper
        // restores on heartbeat loss and the apply can stall on a dead session.
        if self.snapshot.isCooling || UserDefaults.standard.bool( forKey: FanControlDefaults.recoveryNeeded )
        {
            self.sendHeartbeat()
        }
        else if self.isWorking
        {
            return
        }
        else if self.panelVisibleCount > 0
        {
            self.refresh()
        }
        else
        {
            self.stopIdleWorkIfPossible()
        }
    }

    private func startObservingSystemState()
    {
        guard self.observingWorkspace == false
        else
        {
            return
        }

        self.observingWorkspace = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector( self.systemWillSleep( _: ) ),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc
    private func systemWillSleep( _ notification: Notification )
    {
        if self.snapshot.isCooling || UserDefaults.standard.bool( forKey: FanControlDefaults.recoveryNeeded )
        {
            self.restoreAutomatic()
        }
    }

    private func postUpdate()
    {
        NotificationCenter.default.post( name: .fanControlDidUpdate, object: self )
    }
}
