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

    @objc private dynamic var minSpeed   = 0
    @objc private dynamic var maxSpeed   = 100
    
    private var fanIndex: Int?
    
    public override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Expected name format: F0Ac, F1Ac, etc.
        if let index = Int( self.name.dropFirst().prefix( 1 ) )
        {
            self.fanIndex = index
            self.updateLimits()
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
}
