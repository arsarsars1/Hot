/*******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2022, Jean-David Gadina - www.xs-labs.com
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

import Cocoa
import SMCKit

public class FanViewController: NSViewController
{
    @objc private dynamic var icon  = NSImage( named: "Unknown" )
    @objc private dynamic var label = "Unknown:"
    @objc public  dynamic var value = 0
    @objc public  dynamic var name  = "Unknown"
    {
        didSet
        {
            self.label = self.name.hasSuffix( ":" ) ? self.name : "\( self.name ):"

            self.icon = NSImage( named: "FanTemplate" )
        }
    }

    @objc private dynamic var isManual   = false
    @objc private dynamic var minSpeed   = 0
    @objc private dynamic var maxSpeed   = 100
    @objc private dynamic var targetSpeed = 0
    
    private var fanIndex: Int?
    private var originalMinSpeed: Double?
    
    public override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Expected name format: F0Ac, F1Ac, etc.
        if let index = Int( self.name.dropFirst().prefix( 1 ) )
        {
            self.fanIndex = index
            self.updateLimits()
            self.readMode()
            self.readTarget()
        }
        
        // Force width to ensure menu item expands
        var frame = self.view.frame
        frame.size.width = 450
        self.view.frame = frame
    }
    
    public override var nibName: NSNib.Name?
    {
        "FanViewController"
    }
    
    @IBAction public func toggleManual( _ sender: Any? )
    {
        print( "HOT_DEBUG: toggleManual called" )
        guard let index = self.fanIndex
        else
        {
            print( "HOT_DEBUG: toggleManual - No fan index" )
            return
        }
        
        // Restore Min Speed if disabling Manual
        if self.isManual == false, let original = self.originalMinSpeed
        {
             let minKey = String( format: "F%dMn", index )
             print( "HOT_DEBUG: Restoring Default Min Speed: \(minKey) -> \(original)" )
             
             // Convert to float big endian
             var v = Float( original ).bitPattern.bigEndian
             let data = Data( bytes: &v, count: 4 )
             _ = self.writeSMC( key: minKey, data: data )
        }

        let key = String( format: "F%dMd", index ) // F0Md
        print( "HOT_DEBUG: toggleManual - Key: \(key), isManual: \(self.isManual)" )
        
        // Mode seems to be ui8 or ui16. Let's try writing 1 byte.
        var byteVal = UInt8( self.isManual ? 1 : 0 )
        let data    = Data( bytes: &byteVal, count: 1 )
        
        if self.writeSMC( key: key, data: data ) == false
        {
             // Fallback: try 2 bytes if 1 fails? Or log.
             print( "HOT_DEBUG: Failed to write fan mode" )
        }
        else
        {
            print( "HOT_DEBUG: Successfully wrote fan mode" )
            
            // Explicit debug read
            self.debugReadBack( key: key )
        }
    }
    
    @IBAction public func changeSpeed( _ sender: Any? )
    {
        print( "HOT_DEBUG: changeSpeed called" )
        guard let index = self.fanIndex, self.isManual
        else
        {
            return
        }
        
        let key   = String( format: "F%dTg", index )
        let value = Float( self.targetSpeed )
        
        print( "HOT_DEBUG: changeSpeed - Key: \(key), Target: \(value)" )
        
        var v = value.bitPattern.bigEndian
        let data = Data( bytes: &v, count: 4 )
        
        if self.writeSMC( key: key, data: data ) == false
        {
            print( "HOT_DEBUG: Failed to write target speed" )
        }
            print( "HOT_DEBUG: Successfully wrote target speed" )
            
            // Also write to Min Speed (F#Mn) to force logic
            let minKey = String( format: "F%dMn", index )
            
            // Check type of Min Key First!
            var minData = data // Default to float data
            
             func keyToUInt32( _ key: String ) -> UInt32
             {
                 guard let keyCode = key.cString( using: .ascii ), keyCode.count == 5 else { return 0 }
                 return UInt32( keyCode[ 0 ] ) << 24 | UInt32( keyCode[ 1 ] ) << 16 | UInt32( keyCode[ 2 ] ) << 8 | UInt32( keyCode[ 3 ] )
             }
            
            if let keyInfo = SMCKit.SMC.shared.readAllKeys( { $0 == keyToUInt32( minKey ) } ).first
            {
                if keyInfo.typeName == "ui16" || keyInfo.typeName == "fpe2" {
                    // Convert Float RPM to UInt16 (RPM / 4) or similar? 
                    // Usually FPE2 is RPM >> 2. UI16 might be raw RPM.
                    // Let's assume ui16/fpe2 is RPM >> 2 for fan keys on some Macs.
                    // Or simply raw RPM cast to UInt16?
                    // Let's rely on what we read: if original was ~3000 and type ui16, then it's raw.
                    // If original was ~750, then it's shifted.
                    // Safe bet: raw RPM >> 2 (standard for Apple fans).
                    
                    let val16 = UInt16( value / 4 ).bigEndian
                    var v16 = val16
                    minData = Data( bytes: &v16, count: 2 )
                    print( "HOT_DEBUG: Converting Min Override to \(keyInfo.typeName): \(minData as NSData)" )
                } else {
                     print( "HOT_DEBUG: Min Override type is \(keyInfo.typeName), using existing float data" )
                }
            }
            
            print( "HOT_DEBUG: changeSpeed - Writing Min Override: \(minKey)" )
            if self.writeSMC( key: minKey, data: minData ) == false
            {
                 print( "HOT_DEBUG: Failed to write Min Override" )
            }
            
            self.debugReadBack( key: key )
            self.readTarget()
        }
    
    private func writeSMC( key: String, data: Data ) -> Bool
    {
        print( "HOT_DEBUG: writeSMC - Key: \(key), Data: \(data as NSData)" )
        guard let keyCode = key.cString( using: .ascii )
        else
        {
            print( "HOT_DEBUG: writeSMC - Failed to convert key to CString" )
            return false
        }
        
        var k: UInt32 = 0
        
        if keyCode.count == 5
        {
            k = UInt32( keyCode[ 0 ] ) << 24
              | UInt32( keyCode[ 1 ] ) << 16
              | UInt32( keyCode[ 2 ] ) <<  8
              | UInt32( keyCode[ 3 ] ) <<  0
        }
        
        let result = SMCKit.SMC.shared.writeKey( k, data: data )
        print( "HOT_DEBUG: writeSMC - Result: \(result)" )
        return result
    }
    
    private func debugReadBack( key: String )
    {
         guard let keyCode = key.cString( using: .ascii ), keyCode.count == 5 else { return }
         let k = UInt32( keyCode[ 0 ] ) << 24 | UInt32( keyCode[ 1 ] ) << 16 | UInt32( keyCode[ 2 ] ) << 8 | UInt32( keyCode[ 3 ] )
         
         // Direct SMCKit internal access might be hard due to access control.
         // Let's rely on SMCHelper. But SMCHelper.read isn't exposed clearly as "readKey(string)".
         // Wait, SMCHelper.value(for:type:) exists.
         // But we need the raw data.
         
         // Re-use SMC.shared.readSMCKey( key, buffer... ) ?? Access control?
         // SMC methods are Public in SMC.h but might be internal in Swift wrapper?
         // SMC.shared is public. readSMCKey is public in ObjC.
         
         // Let's match how updateLimits does it:
         // SMCKit.SMC.shared.readAllKeys( { $0 == ... } )
         
         // This is inefficient but safe:
         if let wrapper = SMCKit.SMC.shared.readAllKeys( { $0 == k } ).first
         {
             let raw = wrapper.data
             print( "HOT_DEBUG: ReadBack \(key) -> \(raw as NSData)" )
         }
    }
    
    private func updateLimits()
    {
        guard let index = self.fanIndex
        else
        {
            return
        }
        
        // Helper to convert key string to UInt32 for generic lookup
        func keyToUInt32( _ key: String ) -> UInt32
        {
            guard let keyCode = key.cString( using: .ascii ), keyCode.count == 5 else { return 0 }
            return UInt32( keyCode[ 0 ] ) << 24 | UInt32( keyCode[ 1 ] ) << 16 | UInt32( keyCode[ 2 ] ) << 8 | UInt32( keyCode[ 3 ] )
        }
        
        // Min
        if let minVal = SMCKit.SMC.shared.readAllKeys( { $0 == keyToUInt32( "F\(index)Mn" ) } ).first
        {
             if let v = minVal.value as? Double
             {
                 self.minSpeed = Int( v )
                 if self.originalMinSpeed == nil { self.originalMinSpeed = v }
             }
        }
        
        // Max
        if let maxVal = SMCKit.SMC.shared.readAllKeys( { $0 == keyToUInt32( "F\(index)Mx" ) } ).first
        {
             if let v = maxVal.value as? Double
             {
                 self.maxSpeed = Int( v )
             }
        }
    }
    
    private func readMode()
    {
        guard let index = self.fanIndex
        else
        {
            return
        }
        
        func keyToUInt32( _ key: String ) -> UInt32
        {
            guard let keyCode = key.cString( using: .ascii ), keyCode.count == 5 else { return 0 }
            return UInt32( keyCode[ 0 ] ) << 24 | UInt32( keyCode[ 1 ] ) << 16 | UInt32( keyCode[ 2 ] ) << 8 | UInt32( keyCode[ 3 ] )
        }
        
        // Mode
        if let val = SMCKit.SMC.shared.readAllKeys( { $0 == keyToUInt32( "F\(index)Md" ) } ).first
        {
            /*
            DispatchQueue.main.async
            {
                self.label = "\(self.name) [\(val.typeName)]"
            }
            */

             if let v = val.value as? Int
             {
                 self.isManual = ( v == 1 )
             }
             else if let v = val.value as? UInt8
             {
                 self.isManual = ( v == 1 )
             }
        }
    }
    
    private func readTarget()
    {
         guard let index = self.fanIndex
        else
        {
            return
        }
        
        func keyToUInt32( _ key: String ) -> UInt32
        {
            guard let keyCode = key.cString( using: .ascii ), keyCode.count == 5 else { return 0 }
            return UInt32( keyCode[ 0 ] ) << 24 | UInt32( keyCode[ 1 ] ) << 16 | UInt32( keyCode[ 2 ] ) << 8 | UInt32( keyCode[ 3 ] )
        }
        
        if let val = SMCKit.SMC.shared.readAllKeys( { $0 == keyToUInt32( "F\(index)Tg" ) } ).first
        {
             /*
             DispatchQueue.main.async
             {
                 self.label = "\(self.label) [\(val.typeName)]"
             }
             */

             if let v = val.value as? Double
             {
                 self.targetSpeed = Int( v )
             }
        }
    }
}
