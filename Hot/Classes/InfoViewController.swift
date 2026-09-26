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
    @objc public private( set ) dynamic var fanControlExpanded: Bool = false

    public var onUpdate: ( () -> Void )?

    #if arch( arm64 )
        @objc public private( set ) dynamic var isARM = true
    #else
        @objc public private( set ) dynamic var isARM = false
    #endif

    @IBOutlet public private( set ) var graphView:       GraphView?
    @IBOutlet public private( set ) var fanGraphView:    GraphView?
    @IBOutlet private               var graphViewHeight: NSLayoutConstraint!
    @IBOutlet private               var metricsStack:    NSStackView?
    @IBOutlet private               var pressureRow:     NSView?
    @IBOutlet private               var temperatureRow:  NSView?
    @IBOutlet private               var fanRow:          NSView?

    private var maxFanSpeed: Int = 6000
    private var fanControlPanel: FanControlPanelController?
    private var sidebarContainer: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarMinHeightConstraint: NSLayoutConstraint?
    private var rootWidthConstraint: NSLayoutConstraint?
    private var chevronLabel: NSTextField?

    deinit
    {
        self.timer?.invalidate()
        UserDefaults.standard.removeObserver( self, forKeyPath: "refreshInterval" )
    }

    public override var nibName: NSNib.Name?
    {
        "InfoViewController"
    }



    public override func viewDidLoad()
    {
        super.viewDidLoad()

        self.graphViewHeight.constant = 0

        // Force width to ensure menu item expands and fits the new dropdown
        var frame = self.view.frame
        frame.size.width = 450
        self.view.frame = frame

        self.setTimer()
        self.log.refresh
        { [ weak self ] in

            DispatchQueue.main.async
            { [ weak self ] in

                self?.update()
            }
        }

        UserDefaults.standard.addObserver( self, forKeyPath: "refreshInterval",  options: [], context: nil )

        // Defer SMC reads so we do not race ThermalLog.refresh on launch.
        DispatchQueue.global( qos: .utility ).async
        {
            [ weak self ] in
            self?.detectMaxFanSpeed()
        }

        self.installFanControlSidebar()
        self.installMetricRowClicks()
    }

    @objc
    public func toggleFanControlSidebar( _ sender: Any? )
    {
        self.setFanControlExpanded( !self.fanControlExpanded, animated: true )
    }

    public func setFanControlExpanded( _ expanded: Bool, animated: Bool )
    {
        guard self.fanControlExpanded != expanded
        else
        {
            return
        }

        self.fanControlExpanded = expanded
        self.chevronLabel?.stringValue = expanded ? "▾" : "▸"
        self.sidebarContainer?.isHidden = expanded == false
        self.sidebarWidthConstraint?.constant = expanded ? 360 : 0
        self.sidebarMinHeightConstraint?.isActive = expanded
        self.rootWidthConstraint?.constant = expanded ? 820 : 450

        if expanded
        {
            self.ensureFanControlPanelLoaded()
            self.fanControlPanel?.prepareForSidebarDisplay()
        }
        else
        {
            self.fanControlPanel?.prepareForSidebarHide()
        }

        let apply =
        {
            self.view.layoutSubtreeIfNeeded()
            if let menu = self.view.enclosingMenuItem?.menu
            {
                menu.itemChanged( self.view.enclosingMenuItem! )
            }
            var frame = self.view.frame
            frame.size.width = expanded ? 820 : 450
            self.view.frame = frame
            self.view.needsLayout = true
            self.view.window?.layoutIfNeeded()
        }

        if animated
        {
            NSAnimationContext.runAnimationGroup
            {
                context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                apply()
            }
        }
        else
        {
            apply()
        }
    }

    private func installFanControlSidebar()
    {
        guard let metricsStack = self.metricsStack,
              let superview = metricsStack.superview
        else
        {
            return
        }

        let shell = NSView()
        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent( 0.55 ).cgColor
        shell.layer?.cornerRadius = 10
        shell.isHidden = true

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        if #available( macOS 10.14, * )
        {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        else
        {
            separator.layer?.backgroundColor = NSColor( white: 0.75, alpha: 0.8 ).cgColor
        }

        // Detach from the XIB first, then wrap — never removeFromSuperview after
        // NSStackView(views:) already adopted the metrics stack (that orphaned temps/graphs).
        metricsStack.removeFromSuperview()

        let horizontal = NSStackView()
        horizontal.orientation = .horizontal
        horizontal.alignment = .top
        horizontal.spacing = 12
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        horizontal.setHuggingPriority( .defaultHigh, for: .horizontal )
        horizontal.addArrangedSubview( metricsStack )
        horizontal.addArrangedSubview( separator )
        horizontal.addArrangedSubview( shell )

        superview.addSubview( horizontal )

        let width = shell.widthAnchor.constraint( equalToConstant: 0 )
        self.sidebarWidthConstraint = width
        self.sidebarContainer = shell

        let minHeight = shell.heightAnchor.constraint( greaterThanOrEqualToConstant: 420 )
        minHeight.isActive = false
        self.sidebarMinHeightConstraint = minHeight

        let rootWidth = self.view.widthAnchor.constraint( equalToConstant: 450 )
        rootWidth.priority = .required
        self.rootWidthConstraint = rootWidth

        NSLayoutConstraint.activate(
            [
                horizontal.leadingAnchor.constraint( equalTo: superview.leadingAnchor, constant: 20 ),
                horizontal.trailingAnchor.constraint( equalTo: superview.trailingAnchor, constant: -20 ),
                horizontal.topAnchor.constraint( equalTo: superview.topAnchor, constant: 5 ),
                horizontal.bottomAnchor.constraint( equalTo: superview.bottomAnchor ),
                separator.widthAnchor.constraint( equalToConstant: 1 ),
                separator.heightAnchor.constraint( equalTo: metricsStack.heightAnchor ),
                width,
                rootWidth,
            ]
        )
    }

    private func ensureFanControlPanelLoaded()
    {
        guard self.fanControlPanel == nil, let shell = self.sidebarContainer
        else
        {
            return
        }

        let panel = FanControlPanelController( compact: true )
        self.fanControlPanel = panel
        self.addChild( panel )

        shell.addSubview( panel.view )
        panel.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate(
            [
                panel.view.leadingAnchor.constraint( equalTo: shell.leadingAnchor ),
                panel.view.trailingAnchor.constraint( equalTo: shell.trailingAnchor ),
                panel.view.topAnchor.constraint( equalTo: shell.topAnchor ),
                panel.view.bottomAnchor.constraint( equalTo: shell.bottomAnchor ),
            ]
        )
    }

    private func installMetricRowClicks()
    {
        let rows = [ self.pressureRow, self.temperatureRow, self.fanRow ].compactMap { $0 }

        for row in rows
        {
            let click = NSClickGestureRecognizer( target: self, action: #selector( self.toggleFanControlSidebar( _: ) ) )
            row.addGestureRecognizer( click )
            row.toolTip = "Show Fan Control sidebar"
        }

        if let fanRow = self.fanRow
        {
            let chevron = NSTextField( labelWithString: "▸" )
            chevron.font = NSFont.systemFont( ofSize: 11, weight: .semibold )
            chevron.textColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            fanRow.addSubview( chevron )
            NSLayoutConstraint.activate(
                [
                    chevron.trailingAnchor.constraint( equalTo: fanRow.trailingAnchor ),
                    chevron.centerYAnchor.constraint( equalTo: fanRow.centerYAnchor ),
                ]
            )
            self.chevronLabel = chevron
        }
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
        
        if maxSpeed > 1000
        {
            DispatchQueue.main.async
            {
                self.maxFanSpeed = Int( maxSpeed )
            }
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
        { [ weak self ] _ in

            guard let self = self
            else
            {
                return
            }

            self.log.refresh
            { [ weak self ] in

                DispatchQueue.main.async
                { [ weak self ] in

                    self?.update()
                }
            }
        }

        RunLoop.main.add( timer, forMode: .common )

        self.timer = timer
    }
    
    public override func viewDidLayout()
    {
        super.viewDidLayout()
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
