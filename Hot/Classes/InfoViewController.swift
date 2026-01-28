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

public class InfoViewController: NSViewController
{
    private var timer: Timer?

    @objc public private( set ) dynamic var log                   = ThermalLog()
    @objc public private( set ) dynamic var schedulerLimit:  Int  = 0
    @objc public private( set ) dynamic var availableCPUs:   Int  = 0
    @objc public private( set ) dynamic var speedLimit:      Int  = 0
    @objc public private( set ) dynamic var temperature:     Int  = 0
    @objc public private( set ) dynamic var fanSpeed:        Int  = 0
    @objc public private( set ) dynamic var thermalPressure: Int  = 0
    @objc public private( set ) dynamic var hasSensors:      Bool = false
    @objc public private( set ) dynamic var hasFans:         Bool = false

    public var onUpdate: ( () -> Void )?

    #if arch( arm64 )
        @objc public private( set ) dynamic var isARM = true
    #else
        @objc public private( set ) dynamic var isARM = false
    #endif

    @IBOutlet public private( set ) var graphView:       GraphView?
    @IBOutlet public private( set ) var fanGraphView:    GraphView?
    @IBOutlet private               var graphViewHeight: NSLayoutConstraint!
    
    private var maxFanSpeed: Int = 6000

    deinit
    {
        UserDefaults.standard.removeObserver( self, forKeyPath: "refreshInterval" )
    }

    public override var nibName: NSNib.Name?
    {
        "InfoViewController"
    }

    @IBOutlet private var fanModeDropdown: NSButton!

    @IBAction private func changeFanMode( _ sender: NSButton )
    {
        let isManual = sender.state == .on
        let key      = "F0Md" // Assumes Fan 0 for the main info view
        
        // Debug print
        print( "HOT_DEBUG: InfoView changeFanMode - Key: \(key), Manual: \(isManual)" )
        
        // Similar to FanViewController logic
        var byteVal = UInt8( isManual ? 1 : 0 )
        let data    = Data( bytes: &byteVal, count: 1 )
        
        guard let keyCode = key.cString( using: .ascii )
        else
        {
            return
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
        print( "HOT_DEBUG: InfoView writeSMC - Result: \(result)" )
    }


    public override func viewDidLoad()
    {
        super.viewDidLoad()

        self.graphViewHeight.constant = 0

        // Force width to ensure menu item expands and fits the new dropdown
        var frame = self.view.frame
        frame.size.width = 450
        self.view.frame = frame
        print( "HOT_DEBUG: InfoView viewDidLoad - Frame width set to: \(self.view.frame.width)" )

        self.setTimer()
        self.log.refresh
        {
            DispatchQueue.main.async
            {
                self.update()
            }
        }

        UserDefaults.standard.addObserver( self, forKeyPath: "refreshInterval",  options: [], context: nil )
        
        self.detectMaxFanSpeed()
    }
    
    private func detectMaxFanSpeed()
    {
        // helper to make 4-char code
        func key( _ s: String ) -> UInt32
        {
            guard let c = s.cString( using: .ascii ), c.count == 5 else { return 0 }
            return UInt32( c[ 0 ] ) << 24 | UInt32( c[ 1 ] ) << 16 | UInt32( c[ 2 ] ) << 8 | UInt32( c[ 3 ] )
        }

        var maxSpeed = 0.0
        
        // Check F0Mx -> F4Mx
        for i in 0 ..< 5
        {
            let k = key( "F\(i)Mx" )
            if let val = SMCKit.SMC.shared.readAllKeys( { $0 == k } ).first
            {
                if let v = val.value as? Double {
                    maxSpeed = max( maxSpeed, v )
                } else if let v = val.value as? Float {
                    maxSpeed = max( maxSpeed, Double(v) )
                }
            }
        }
        
        if maxSpeed > 1000 {
            self.maxFanSpeed = Int( maxSpeed )
            print( "HOT_DEBUG: Detected Max Fan Speed: \(self.maxFanSpeed)" )
        }
    }

    public override func observeValue( forKeyPath keyPath: String?, of object: Any?, change: [ NSKeyValueChangeKey: Any ]?, context: UnsafeMutableRawPointer? )
    {
        if let object = object as? NSObject, object == UserDefaults.standard, keyPath == "refreshInterval"
        {
            self.setTimer()
        }
        else
        {
            super.observeValue( forKeyPath: keyPath, of: object, change: change, context: context )
        }
    }

    private func setTimer()
    {
        self.timer?.invalidate()

        var interval = UserDefaults.standard.integer( forKey: "refreshInterval" )

        if interval <= 0
        {
            interval = 2
        }

        let timer = Timer( timeInterval: Double( interval ), repeats: true )
        {
            _ in self.log.refresh
            {
                DispatchQueue.main.async
                {
                    self.update()
                }
            }
        }

        RunLoop.main.add( timer, forMode: .common )

        self.timer = timer
    }
    
    public override func viewDidLayout()
    {
        super.viewDidLayout()
        
        if let btn = self.fanModeDropdown
        {
            print( "HOT_DEBUG: viewDidLayout - Dropdown Frame: \(btn.frame), Superview Frame: \(btn.superview?.frame ?? .zero)" )
            print( "HOT_DEBUG: viewDidLayout - Dropdown Hidden: \(btn.isHidden), Enabled: \(btn.isEnabled)" )
        }
    }

    private func update()
    {
        self.hasSensors = self.log.sensors.isEmpty == false
        self.hasFans = self.log.fans.isEmpty == false

        if let n = self.log.schedulerLimit?.intValue
        {
            self.schedulerLimit = n
        }

        if let n = self.log.availableCPUs?.intValue
        {
            self.availableCPUs = n
        }

        if let n = self.log.speedLimit?.intValue
        {
            self.speedLimit = n
        }

        if let n = self.log.temperature?.intValue
        {
            self.temperature = n
        }

        if let n = self.log.fanSpeed?.intValue
        {
            self.fanSpeed = n
        }

        if let n = self.log.thermalPressure?.intValue
        {
            self.thermalPressure = n
        }

        if self.speedLimit > 0, self.temperature > 0
        {
            self.graphView?.addData( speed: self.speedLimit, temperature: self.temperature )
        }
        else if self.temperature > 0
        {
            self.graphView?.addData( speed: 100, temperature: self.temperature )
        }
        
        // Update Fan Graph
        if let rpm = self.log.fanSpeed?.intValue
        {
            let normalized = Int( ( Double( rpm ) / Double( self.maxFanSpeed ) ) * 100.0 )
            // Pass to speed parameter (Blue line)
            self.fanGraphView?.addData( speed: normalized, temperature: 0 )
        }

        self.graphViewHeight.constant = self.graphView?.canDisplay ?? false ? 100 : 0

        self.onUpdate?()
    }
}
