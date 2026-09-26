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

/// Builds the status-menu **Fan Control ▸** hierarchy (System / Manual / Curve).
final class FanControlStatusMenuController: NSObject, NSMenuDelegate
{
    private static let manualPresets = [ 0, 10, 25, 50, 75, 100 ]

    private weak var menu: NSMenu?
    private weak var windowTarget: AnyObject?
    private var windowAction: Selector = #selector( ApplicationDelegate.showFanControlWindow( _: ) )

    private let service = FanControlService.shared
    private var slider: NSSlider?
    private var sliderLabel: NSTextField?
    private var observer: NSObjectProtocol?

    func install( into menu: NSMenu, windowTarget: AnyObject, windowAction: Selector )
    {
        self.menu = menu
        self.windowTarget = windowTarget
        self.windowAction = windowAction
        menu.delegate = self
        self.rebuild()

        self.observer = NotificationCenter.default.addObserver(
            forName: .fanControlDidUpdate,
            object: nil,
            queue: .main
        )
        {
            [ weak self ] _ in
            // Keep checkmarks fresh while the menu stays open.
            guard let menu = self?.menu, menu.supermenu?.highlightedItem?.submenu === menu
            else
            {
                return
            }
            self?.rebuild()
        }
    }

    deinit
    {
        if let observer
        {
            NotificationCenter.default.removeObserver( observer )
        }
    }

    func menuWillOpen( _ menu: NSMenu )
    {
        self.rebuild()
    }

    // MARK: - Actions

    @objc
    private func selectSystem( _ sender: Any? )
    {
        self.service.applyConfiguration(
            FanControlConfiguration( mode: .system, manualLevel: FanControlPolicy.defaultCoolingLevel, curves: [] )
        )
    }

    @objc
    private func selectManualPreset( _ sender: NSMenuItem )
    {
        let level = sender.tag
        guard FanControlPolicy.validCoolingLevel( level )
        else
        {
            return
        }
        UserDefaults.standard.set( level, forKey: FanControlDefaults.coolingLevel )
        UserDefaults.standard.set( FanControlMode.manual.rawValue, forKey: FanControlDefaults.mode )
        self.service.applyConfiguration( .manual( level: level ) )
    }

    @objc
    private func manualSliderChanged( _ sender: NSSlider )
    {
        let step = FanControlPolicy.coolingLevelStep
        var level = Int( sender.doubleValue.rounded() )
        level = ( level / step ) * step
        level = min( FanControlPolicy.maximumCoolingLevel, max( FanControlPolicy.minimumCoolingLevel, level ) )
        sender.doubleValue = Double( level )
        self.sliderLabel?.stringValue = "\( level )%"
    }

    @objc
    private func manualSliderInteraction( _ sender: NSSlider )
    {
        self.manualSliderChanged( sender )

        if NSApp.currentEvent?.type == .leftMouseUp
        {
            let level = Int( sender.doubleValue.rounded() )
            UserDefaults.standard.set( level, forKey: FanControlDefaults.coolingLevel )
            UserDefaults.standard.set( FanControlMode.manual.rawValue, forKey: FanControlDefaults.mode )
            self.service.applyConfiguration( .manual( level: level ) )
        }
    }

    @objc
    private func applySavedCurve( _ sender: Any? )
    {
        let defaults = UserDefaults.standard
        let curves: [ FanControlCurve ]

        if let raw = defaults.string( forKey: FanControlDefaults.curves ),
           let decoded = FanControlConfiguration.decodeCurves( raw )
        {
            curves = decoded
        }
        else
        {
            curves = [ FanControlConfiguration.defaultCurve ]
        }

        defaults.set( FanControlMode.curve.rawValue, forKey: FanControlDefaults.mode )
        self.service.applyConfiguration( .curve( curves ) )
    }

    @objc
    private func authorizeFanControl( _ sender: Any? )
    {
        self.service.authorize()
    }

    // MARK: - Build

    private func rebuild()
    {
        guard let menu
        else
        {
            return
        }

        menu.removeAllItems()

        let enabled = self.service.accessState == .enabled
        let cooling = self.service.snapshot.isCooling
        let activeMode = self.service.snapshot.configuration?.mode
            ?? FanControlMode( rawValue: UserDefaults.standard.string( forKey: FanControlDefaults.mode ) ?? "" )
        let activeLevel = self.service.snapshot.coolingLevel
            ?? UserDefaults.standard.integer( forKey: FanControlDefaults.coolingLevel )

        let system = NSMenuItem( title: "System", action: #selector( selectSystem( _: ) ), keyEquivalent: "" )
        system.target = self
        system.state = ( cooling == false || activeMode == .system ) ? .on : .off
        system.isEnabled = enabled || cooling
        menu.addItem( system )

        let manual = NSMenuItem( title: "Manual", action: nil, keyEquivalent: "" )
        manual.state = ( cooling && activeMode == .manual ) ? .on : .off
        manual.submenu = self.makeManualMenu( enabled: enabled, activeLevel: activeLevel, active: cooling && activeMode == .manual )
        menu.addItem( manual )

        let curve = NSMenuItem( title: "Curve", action: nil, keyEquivalent: "" )
        curve.state = ( cooling && activeMode == .curve ) ? .on : .off
        curve.submenu = self.makeCurveMenu( enabled: enabled )
        menu.addItem( curve )

        menu.addItem( .separator() )

        if enabled == false
        {
            let allow = NSMenuItem(
                title: self.service.clientMeetsCodeRequirement ? "Allow Fan Control…" : "Needs Signed Hot from Applications",
                action: #selector( authorizeFanControl( _: ) ),
                keyEquivalent: ""
            )
            allow.target = self
            allow.isEnabled = self.service.clientMeetsCodeRequirement && self.service.accessState != .unsupportedOS
            menu.addItem( allow )
        }

        let window = NSMenuItem( title: "Fan Control Window…", action: self.windowAction, keyEquivalent: "" )
        window.target = self.windowTarget
        menu.addItem( window )
    }

    private func makeManualMenu( enabled: Bool, activeLevel: Int, active: Bool ) -> NSMenu
    {
        let menu = NSMenu( title: "Manual" )

        for level in Self.manualPresets
        {
            let item = NSMenuItem(
                title: "\( level )%",
                action: #selector( selectManualPreset( _: ) ),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = level
            item.isEnabled = enabled
            item.state = ( active && activeLevel == level ) ? .on : .off
            menu.addItem( item )
        }

        menu.addItem( .separator() )

        let sliderItem = NSMenuItem()
        sliderItem.view = self.makeManualSliderView( level: activeLevel, enabled: enabled )
        menu.addItem( sliderItem )

        return menu
    }

    private func makeCurveMenu( enabled: Bool ) -> NSMenu
    {
        let menu = NSMenu( title: "Curve" )

        let apply = NSMenuItem(
            title: "Apply Saved Curve",
            action: #selector( applySavedCurve( _: ) ),
            keyEquivalent: ""
        )
        apply.target = self
        apply.isEnabled = enabled
        menu.addItem( apply )

        let edit = NSMenuItem( title: "Edit Curve…", action: self.windowAction, keyEquivalent: "" )
        edit.target = self.windowTarget
        menu.addItem( edit )

        return menu
    }

    private func makeManualSliderView( level: Int, enabled: Bool ) -> NSView
    {
        let width: CGFloat = 220
        let height: CGFloat = 44
        let root = NSView( frame: NSRect( x: 0, y: 0, width: width, height: height ) )

        let label = NSTextField( labelWithString: "\( level )%" )
        label.font = NSFont.monospacedDigitSystemFont( ofSize: 12, weight: .medium )
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider( value: Double( level ), minValue: 0, maxValue: 100, target: self, action: #selector( manualSliderInteraction( _: ) ) )
        slider.isContinuous = true
        slider.isEnabled = enabled
        slider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview( label )
        root.addSubview( slider )

        NSLayoutConstraint.activate(
            [
                label.trailingAnchor.constraint( equalTo: root.trailingAnchor, constant: -14 ),
                label.centerYAnchor.constraint( equalTo: root.centerYAnchor ),
                label.widthAnchor.constraint( equalToConstant: 40 ),

                slider.leadingAnchor.constraint( equalTo: root.leadingAnchor, constant: 14 ),
                slider.trailingAnchor.constraint( equalTo: label.leadingAnchor, constant: -8 ),
                slider.centerYAnchor.constraint( equalTo: root.centerYAnchor ),
            ]
        )

        self.slider = slider
        self.sliderLabel = label
        return root
    }
}
