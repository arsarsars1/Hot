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

import Foundation
import IOKit

// MARK: - AppleSMC parameter layout (80 bytes)

public struct SMCVersion
{
    public var major: UInt8
    public var minor: UInt8
    public var build: UInt8
    public var reserved: UInt8
    public var release: UInt16

    public init()
    {
        self.major    = 0
        self.minor    = 0
        self.build    = 0
        self.reserved = 0
        self.release  = 0
    }
}

public struct SMCPLimitData
{
    public var version: UInt16
    public var length: UInt16
    public var cpuPLimit: UInt32
    public var gpuPLimit: UInt32
    public var memPLimit: UInt32

    public init()
    {
        self.version   = 0
        self.length    = 0
        self.cpuPLimit = 0
        self.gpuPLimit = 0
        self.memPLimit = 0
    }
}

public struct SMCKeyInfoData
{
    public var dataSize: UInt32
    public var dataType: UInt32
    public var dataAttributes: UInt8

    public init()
    {
        self.dataSize       = 0
        self.dataType       = 0
        self.dataAttributes = 0
    }
}

public struct SMCParamStruct
{
    public var key: UInt32
    public var vers: SMCVersion
    public var pLimitData: SMCPLimitData
    public var keyInfo: SMCKeyInfoData
    public var padding: UInt16
    public var result: UInt8
    public var status: UInt8
    public var data8: UInt8
    public var data32: UInt32
    public var bytes: ( UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8 )

    public init()
    {
        self.key        = 0
        self.vers       = SMCVersion()
        self.pLimitData = SMCPLimitData()
        self.keyInfo    = SMCKeyInfoData()
        self.padding    = 0
        self.result     = 0
        self.status     = 0
        self.data8      = 0
        self.data32     = 0
        self.bytes      = ( 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 )
    }
}

private enum SMCSelector
{
    static let handleYPCEvent: UInt8 = 2
    static let read: UInt8           = 5
    static let write: UInt8          = 6
    static let keyFromIndex: UInt8   = 8
    static let keyInfo: UInt8        = 9
}

public struct SMCKeyDescriptor
{
    public var name: String
    public var key: UInt32
    public var info: SMCKeyInfoData

    public init( name: String, key: UInt32, info: SMCKeyInfoData )
    {
        self.name = name
        self.key  = key
        self.info = info
    }
}

public final class SMCClient
{
    private var connection: io_connect_t = 0

    public init() throws
    {
        let port: mach_port_t

        if #available( macOS 12.0, * )
        {
            port = kIOMainPortDefault
        }
        else
        {
            port = kIOMasterPortDefault
        }

        guard let matching = IOServiceMatching( "AppleSMC" )
        else
        {
            throw SMCClientError.serviceUnavailable
        }

        let service = IOServiceGetMatchingService( port, matching )

        guard service != 0
        else
        {
            throw SMCClientError.serviceUnavailable
        }

        defer
        {
            IOObjectRelease( service )
        }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen( service, mach_task_self_, 0, &connect )

        guard openResult == KERN_SUCCESS
        else
        {
            throw SMCClientError.openFailed( openResult )
        }

        self.connection = connect
    }

    deinit
    {
        if connection != 0
        {
            IOServiceClose( connection )
            connection = 0
        }
    }

    public func key( named name: String ) throws -> SMCKeyDescriptor
    {
        guard let keyCode = SMCValueCodec.fourCC( name )
        else
        {
            throw SMCClientError.invalidKey( name )
        }

        var input = SMCParamStruct()
        input.key   = keyCode
        input.data8 = SMCSelector.keyInfo

        let output = try call( input )

        guard output.result == 0
        else
        {
            throw SMCClientError.keyNotFound( name )
        }

        return SMCKeyDescriptor( name: name, key: keyCode, info: output.keyInfo )
    }

    public func keys( where predicate: ( String ) -> Bool ) throws -> [ SMCKeyDescriptor ]
    {
        let countKey = try key( named: "#KEY" )
        let countData = try readBytes( countKey )
        guard let countValue = SMCValueCodec.decode( data: countData, type: countKey.info.dataType )
        else
        {
            throw SMCClientError.decodeFailed( "#KEY" )
        }

        let count = Int( countValue )
        var found: [ SMCKeyDescriptor ] = []

        for index in 0 ..< count
        {
            var input = SMCParamStruct()
            input.data8  = SMCSelector.keyFromIndex
            input.data32 = UInt32( index )

            let output = try call( input )
            let name   = SMCValueCodec.fourCCString( output.key )

            guard predicate( name )
            else
            {
                continue
            }

            if let descriptor = try? key( named: name )
            {
                found.append( descriptor )
            }
        }

        return found
    }

    public func readValue( _ descriptor: SMCKeyDescriptor ) throws -> Double
    {
        let data = try readBytes( descriptor )

        guard let value = SMCValueCodec.decode( data: data, type: descriptor.info.dataType )
        else
        {
            throw SMCClientError.decodeFailed( descriptor.name )
        }

        return value
    }

    public func readBytes( _ descriptor: SMCKeyDescriptor ) throws -> Data
    {
        var input = SMCParamStruct()
        input.key          = descriptor.key
        input.keyInfo      = descriptor.info
        input.data8        = SMCSelector.read

        let output = try call( input )

        guard output.result == 0
        else
        {
            throw SMCClientError.readFailed( descriptor.name )
        }

        let size = Int( min( descriptor.info.dataSize, 32 ) )
        var bytes = output.bytes
        let buffer = withUnsafeBytes( of: &bytes ) { Data( $0 ) }

        return buffer.prefix( size )
    }

    public func writeValue( _ descriptor: SMCKeyDescriptor, value: Double ) throws
    {
        guard let data = SMCValueCodec.encode( value, type: descriptor.info.dataType )
        else
        {
            throw SMCClientError.encodeFailed( descriptor.name )
        }

        try writeBytes( descriptor, data: data )
    }

    public func writeBytes( _ descriptor: SMCKeyDescriptor, data: Data ) throws
    {
        let size = Int( min( descriptor.info.dataSize, 32 ) )

        guard data.count >= size
        else
        {
            throw SMCClientError.encodeFailed( descriptor.name )
        }

        var input = SMCParamStruct()
        input.key     = descriptor.key
        input.keyInfo = descriptor.info
        input.data8   = SMCSelector.write

        var tuple = input.bytes
        _ = withUnsafeMutableBytes( of: &tuple )
        {
            destination in

            data.prefix( size ).copyBytes( to: destination )
        }
        input.bytes = tuple

        let output = try call( input )

        guard output.result == 0
        else
        {
            throw SMCClientError.writeFailed( descriptor.name )
        }
    }

    private func call( _ input: SMCParamStruct ) throws -> SMCParamStruct
    {
        var inputStruct  = input
        var outputStruct = SMCParamStruct()
        var outputSize   = MemoryLayout< SMCParamStruct >.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32( SMCSelector.handleYPCEvent ),
            &inputStruct,
            MemoryLayout< SMCParamStruct >.stride,
            &outputStruct,
            &outputSize
        )

        guard result == KERN_SUCCESS
        else
        {
            throw SMCClientError.callFailed( result )
        }

        return outputStruct
    }
}

public enum SMCClientError: Error, CustomStringConvertible
{
    case serviceUnavailable
    case openFailed( kern_return_t )
    case invalidKey( String )
    case keyNotFound( String )
    case readFailed( String )
    case writeFailed( String )
    case decodeFailed( String )
    case encodeFailed( String )
    case callFailed( kern_return_t )

    public var description: String
    {
        switch self
        {
            case .serviceUnavailable:     return "AppleSMC is unavailable"
            case .openFailed( let code ): return "IOServiceOpen failed (\( code ))"
            case .invalidKey( let name ): return "Invalid SMC key \( name )"
            case .keyNotFound( let name ): return "SMC key not found: \( name )"
            case .readFailed( let name ): return "SMC read failed: \( name )"
            case .writeFailed( let name ): return "SMC write failed: \( name )"
            case .decodeFailed( let name ): return "SMC decode failed: \( name )"
            case .encodeFailed( let name ): return "SMC encode failed: \( name )"
            case .callFailed( let code ): return "SMC call failed (\( code ))"
        }
    }
}

enum SMCValueCodec
{
    static func fourCC( _ string: String ) -> UInt32?
    {
        guard string.utf8.count == 4
        else
        {
            return nil
        }
        return string.utf8.reduce( 0 ) { ( $0 << 8 ) | UInt32( $1 ) }
    }

    static func fourCCString( _ value: UInt32 ) -> String
    {
        let chars = [
            UInt8( ( value >> 24 ) & 0xff ),
            UInt8( ( value >> 16 ) & 0xff ),
            UInt8( ( value >> 8 ) & 0xff ),
            UInt8( value & 0xff ),
        ]
        return String( bytes: chars, encoding: .ascii ) ?? "????"
    }

    static func decode( data: Data, type: UInt32 ) -> Double?
    {
        let typeName = fourCCString( type )
        let bytes = [ UInt8 ]( data )

        switch typeName
        {
            case "flt " where bytes.count == 4:
                let bits = UInt32( bytes[ 0 ] )
                    | UInt32( bytes[ 1 ] ) << 8
                    | UInt32( bytes[ 2 ] ) << 16
                    | UInt32( bytes[ 3 ] ) << 24
                let value = Double( Float32( bitPattern: bits ) )
                return value.isFinite ? value : nil

            case "fpe2" where bytes.count == 2:
                let raw = UInt16( bytes[ 0 ] ) << 8 | UInt16( bytes[ 1 ] )
                return Double( raw ) / 4.0

            case "sp78" where bytes.count == 2:
                let raw = UInt16( bytes[ 0 ] ) << 8 | UInt16( bytes[ 1 ] )
                return Double( Int16( bitPattern: raw ) ) / 256.0

            case "ui8 " where bytes.count == 1:
                return Double( bytes[ 0 ] )

            case "ui16" where bytes.count == 2:
                return Double( UInt16( bytes[ 0 ] ) << 8 | UInt16( bytes[ 1 ] ) )

            case "ui32" where bytes.count == 4:
                return Double(
                    UInt32( bytes[ 0 ] ) << 24
                        | UInt32( bytes[ 1 ] ) << 16
                        | UInt32( bytes[ 2 ] ) << 8
                        | UInt32( bytes[ 3 ] )
                )

            case "ioft" where bytes.count == 8:
                var raw: UInt64 = 0
                for ( offset, byte ) in bytes.enumerated()
                {
                    raw |= UInt64( byte ) << UInt64( offset * 8 )
                }
                return Double( raw ) / 65_536.0

            default:
                return nil
        }
    }

    static func encode( _ value: Double, type: UInt32 ) -> Data?
    {
        guard value.isFinite, value >= 0
        else
        {
            return nil
        }

        let typeName = fourCCString( type )
        let size: Int

        switch typeName
        {
            case "flt ": size = 4
            case "fpe2": size = 2
            case "ui8 ": size = 1
            case "ui16": size = 2
            case "ui32": size = 4
            default: return nil
        }

        switch typeName
        {
            case "flt " where size == 4:
                let float = Float32( value )
                guard float.isFinite
                else
                {
                    return nil
                }
                let bits = float.bitPattern
                return Data( [
                    UInt8( bits & 0xff ),
                    UInt8( ( bits >> 8 ) & 0xff ),
                    UInt8( ( bits >> 16 ) & 0xff ),
                    UInt8( ( bits >> 24 ) & 0xff ),
                ] )

            case "fpe2" where size == 2:
                let scaled = ( value * 4 ).rounded()
                guard scaled <= Double( UInt16.max )
                else
                {
                    return nil
                }
                let raw = UInt16( scaled )
                return Data( [ UInt8( ( raw >> 8 ) & 0xff ), UInt8( raw & 0xff ) ] )

            case "ui8 " where size == 1:
                guard value.rounded() == value, value <= Double( UInt8.max )
                else
                {
                    return nil
                }
                return Data( [ UInt8( value ) ] )

            case "ui16" where size == 2:
                guard value.rounded() == value, value <= Double( UInt16.max )
                else
                {
                    return nil
                }
                let raw = UInt16( value )
                return Data( [ UInt8( ( raw >> 8 ) & 0xff ), UInt8( raw & 0xff ) ] )

            case "ui32" where size == 4:
                guard value.rounded() == value, value <= Double( UInt32.max )
                else
                {
                    return nil
                }
                let raw = UInt32( value )
                return Data( [
                    UInt8( ( raw >> 24 ) & 0xff ),
                    UInt8( ( raw >> 16 ) & 0xff ),
                    UInt8( ( raw >> 8 ) & 0xff ),
                    UInt8( raw & 0xff ),
                ] )

            default:
                return nil
        }
    }
}
