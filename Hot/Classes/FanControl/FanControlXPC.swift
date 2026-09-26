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

enum FanControlIdentifiers
{
    // Must match the DEVELOPMENT_TEAM / codesign OU used to sign Hot + helper.
    // Local machine uses Abdul Rehman personal team (XS-Labs 326Y53CJMD not available here).
    static let teamID = "KETV72YBM9"
    static let appBundleID = "com.xs-labs.Hot"
    static let helperID = "\( appBundleID ).fan-control"
    static let plistName = "\( helperID ).plist"

    static let appCodeRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\( teamID )\" and identifier \"\( appBundleID )\""
    static let helperCodeRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\( teamID )\" and identifier \"\( helperID )\""
}

@objc
protocol FanControlXPCProtocol
{
    func status( withReply reply: @escaping ( Data ) -> Void )
    func startMaximumCooling( withReply reply: @escaping ( Data ) -> Void )
    func applyConfiguration( _ configuration: Data, withReply reply: @escaping ( Data ) -> Void )
    func heartbeat( withReply reply: @escaping ( Data ) -> Void )
    func restoreAutomatic( withReply reply: @escaping ( Data ) -> Void )
}

enum FanControlIPC
{
    static func encode( _ response: FanControlResponse ) -> Data
    {
        ( try? JSONEncoder().encode( response ) )
            ?? Data( #"{"succeeded":false,"snapshot":{"fans":[],"isCooling":false},"error":"controlFailed"}"#.utf8 )
    }

    static func decode( _ data: Data ) -> FanControlResponse?
    {
        try? JSONDecoder().decode( FanControlResponse.self, from: data )
    }

    static func encode( _ configuration: FanControlConfiguration ) -> Data?
    {
        try? JSONEncoder().encode( configuration )
    }

    static func decodeConfiguration( _ data: Data ) -> FanControlConfiguration?
    {
        guard let configuration = try? JSONDecoder().decode( FanControlConfiguration.self, from: data ),
              FanControlPolicy.validConfiguration( configuration )
        else
        {
            return nil
        }
        return configuration
    }
}
