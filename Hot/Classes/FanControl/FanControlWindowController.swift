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

import Cocoa

/// Shared System / Manual / Curve fan-control UI (window or status-menu sidebar).
final class FanControlPanelController: NSViewController
{
    private let service = FanControlService.shared
    private let compact: Bool

    private var modeControl:       NSSegmentedControl!
    private var intensitySlider:   NSSlider!
    private var intensityLabel:    NSTextField!
    private var rpmStrip:          NSStackView!
    private var statusPill:        NSTextField!
    private var messageLabel:      NSTextField!
    private var actionButton:      NSButton!
    private var manualStack:       NSStackView!
    private var curveScroll:       NSScrollView!
    private var curveListStack:    NSStackView!
    private var addSensorButton:   NSButton!
    private var curveUnavailableLabel: NSTextField!
    private var curveScrollHeightConstraint: NSLayoutConstraint!
    private var coolingLevel:      Int = FanControlPolicy.defaultCoolingLevel
    private var curves:            [ FanControlCurve ] = [ FanControlConfiguration.defaultCurve ]
    private var temperatures:      [ FanControlTemperatureReading ] = []
    private var curveEditors:      [ FanControlCurveEditorView ] = []
    private var rpmCards:          [ FanControlRPMCardView ] = []
    private var isPresented = false

    init( compact: Bool = false )
    {
        self.compact = compact
        super.init( nibName: nil, bundle: nil )
    }

    required init?( coder: NSCoder )
    {
        self.compact = false
        super.init( coder: coder )
    }

    deinit
    {
        NotificationCenter.default.removeObserver( self )
    }

    override func loadView()
    {
        let root = NSView( frame: NSRect( x: 0, y: 0, width: self.compact ? 340 : 440, height: self.compact ? 420 : 420 ) )
        root.wantsLayer = true
        self.view = root
        self.buildUI()
        self.loadPreferences()
        // Compact sidebar defers SMC / XPC work until prepareForSidebarDisplay so
        // status-menu temperature refresh is not starved at launch.
        if self.compact == false
        {
            self.reloadFromService()
        }
    }

    override func viewDidAppear()
    {
        super.viewDidAppear()
        self.reloadFromService()
    }

    func prepareForSidebarDisplay()
    {
        if self.isPresented == false
        {
            self.isPresented = true
            self.service.panelDidAppear()
        }
        self.reloadFromService()
    }

    func prepareForSidebarHide()
    {
        guard self.isPresented
        else
        {
            return
        }

        self.isPresented = false
        self.savePreferences()
        self.service.panelDidDisappear()
    }

    // MARK: - UI

    private func buildUI()
    {
        let content = self.view
        let inset: CGFloat = self.compact ? 10 : 12
        let spacing: CGFloat = self.compact ? 8 : 10

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment   = .leading
        root.spacing     = spacing
        root.edgeInsets  = NSEdgeInsets( top: inset, left: inset, bottom: inset, right: inset )
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview( root )

        NSLayoutConstraint.activate(
            [
                root.leadingAnchor.constraint( equalTo: content.leadingAnchor ),
                root.trailingAnchor.constraint( equalTo: content.trailingAnchor ),
                root.topAnchor.constraint( equalTo: content.topAnchor ),
                root.bottomAnchor.constraint( lessThanOrEqualTo: content.bottomAnchor ),
            ]
        )

        // Title only in compact sidebar — window chrome already shows "Fan Control".
        if self.compact
        {
            let titleRow = NSStackView()
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = 8

            let accent = NSView()
            accent.wantsLayer = true
            if #available( macOS 10.14, * )
            {
                accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            }
            else
            {
                accent.layer?.backgroundColor = NSColor.selectedControlColor.cgColor
            }
            accent.layer?.cornerRadius = 2
            accent.translatesAutoresizingMaskIntoConstraints = false
            accent.widthAnchor.constraint( equalToConstant: 4 ).isActive = true
            accent.heightAnchor.constraint( equalToConstant: 14 ).isActive = true
            titleRow.addArrangedSubview( accent )

            let title = NSTextField( labelWithString: "Fan Control" )
            title.font = NSFont.systemFont( ofSize: 13, weight: .semibold )
            titleRow.addArrangedSubview( title )

            let titleSpacer = NSView()
            titleSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
            titleRow.addArrangedSubview( titleSpacer )
            root.addArrangedSubview( titleRow )
            titleRow.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true
        }

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        self.rpmStrip = NSStackView()
        self.rpmStrip.orientation = .horizontal
        self.rpmStrip.alignment = .top
        self.rpmStrip.spacing = 6
        self.rpmStrip.setHuggingPriority( .defaultHigh, for: .horizontal )
        statusRow.addArrangedSubview( self.rpmStrip )

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        statusRow.addArrangedSubview( statusSpacer )

        self.statusPill = NSTextField( labelWithString: "System" )
        self.statusPill.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.statusPill.textColor = .secondaryLabelColor
        self.statusPill.alignment = .center
        self.statusPill.drawsBackground = false
        self.statusPill.translatesAutoresizingMaskIntoConstraints = false

        let pillWrap = NSView()
        pillWrap.wantsLayer = true
        pillWrap.layer?.cornerRadius = 8
        pillWrap.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        pillWrap.translatesAutoresizingMaskIntoConstraints = false
        pillWrap.addSubview( self.statusPill )
        NSLayoutConstraint.activate(
            [
                self.statusPill.leadingAnchor.constraint( equalTo: pillWrap.leadingAnchor, constant: 8 ),
                self.statusPill.trailingAnchor.constraint( equalTo: pillWrap.trailingAnchor, constant: -8 ),
                self.statusPill.topAnchor.constraint( equalTo: pillWrap.topAnchor, constant: 3 ),
                self.statusPill.bottomAnchor.constraint( equalTo: pillWrap.bottomAnchor, constant: -3 ),
            ]
        )
        statusRow.addArrangedSubview( pillWrap )
        root.addArrangedSubview( statusRow )
        statusRow.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let placeholder = FanControlRPMCardView()
        placeholder.configurePlaceholder( "Reading fans…" )
        self.rpmStrip.addArrangedSubview( placeholder )
        self.rpmCards = [ placeholder ]

        self.messageLabel = NSTextField( wrappingLabelWithString: "" )
        self.messageLabel.font = NSFont.systemFont( ofSize: 11 )
        self.messageLabel.textColor = .secondaryLabelColor
        self.messageLabel.isHidden = true
        root.addArrangedSubview( self.messageLabel )

        self.modeControl = NSSegmentedControl(
            labels: [ "System", "Manual", "Curve" ],
            trackingMode: .selectOne,
            target: self,
            action: #selector( self.modeChanged( _: ) )
        )
        self.modeControl.segmentStyle = .rounded
        self.modeControl.selectedSegment = 0
        root.addArrangedSubview( self.modeControl )
        self.modeControl.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let speedCaption = NSTextField( labelWithString: "Fan speed" )
        speedCaption.font = NSFont.systemFont( ofSize: 12 )
        speedCaption.textColor = .secondaryLabelColor

        self.intensityLabel = NSTextField( labelWithString: "100%" )
        self.intensityLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 12, weight: .semibold )
        self.intensityLabel.alignment = .right
        self.intensityLabel.setContentHuggingPriority( .required, for: .horizontal )

        let manualHeader = NSStackView( views: [ speedCaption, self.intensityLabel ] )
        manualHeader.orientation = .horizontal
        manualHeader.alignment = .centerY
        manualHeader.spacing = 8
        let manualHeaderSpacer = NSView()
        manualHeaderSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        manualHeader.insertArrangedSubview( manualHeaderSpacer, at: 1 )

        self.intensitySlider = NSSlider(
            value: Double( self.coolingLevel ),
            minValue: 0,
            maxValue: 100,
            target: self,
            action: #selector( self.intensityChanged( _: ) )
        )
        self.intensitySlider.numberOfTickMarks = 0
        self.intensitySlider.allowsTickMarkValuesOnly = false

        self.manualStack = NSStackView( views: [ manualHeader, self.intensitySlider ] )
        self.manualStack.orientation = .vertical
        self.manualStack.alignment = .leading
        self.manualStack.spacing = 4
        self.manualStack.isHidden = true
        root.addArrangedSubview( self.manualStack )
        manualHeader.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true
        self.intensitySlider.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        self.curveListStack = NSStackView()
        self.curveListStack.orientation = .vertical
        self.curveListStack.alignment = .leading
        self.curveListStack.spacing = 12
        self.curveListStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview( self.curveListStack )
        NSLayoutConstraint.activate(
            [
                self.curveListStack.leadingAnchor.constraint( equalTo: document.leadingAnchor ),
                self.curveListStack.trailingAnchor.constraint( equalTo: document.trailingAnchor ),
                self.curveListStack.topAnchor.constraint( equalTo: document.topAnchor ),
                self.curveListStack.bottomAnchor.constraint( equalTo: document.bottomAnchor ),
                self.curveListStack.widthAnchor.constraint( equalTo: document.widthAnchor ),
            ]
        )

        self.curveScroll = NSScrollView()
        self.curveScroll.hasVerticalScroller = true
        self.curveScroll.hasHorizontalScroller = false
        self.curveScroll.borderType = .noBorder
        self.curveScroll.drawsBackground = false
        self.curveScroll.documentView = document
        self.curveScroll.translatesAutoresizingMaskIntoConstraints = false
        self.curveScrollHeightConstraint = self.curveScroll.heightAnchor.constraint(
            greaterThanOrEqualToConstant: self.compact ? 200 : 240
        )
        self.curveScrollHeightConstraint.isActive = false
        self.curveScroll.isHidden = true
        root.addArrangedSubview( self.curveScroll )
        self.curveScroll.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true
        root.setHuggingPriority( .defaultHigh, for: .vertical )
        self.curveScroll.setContentHuggingPriority( .defaultLow, for: .vertical )
        self.curveScroll.setContentCompressionResistancePriority( .defaultLow, for: .vertical )

        self.addSensorButton = NSButton(
            title: "Add Sensor",
            target: self,
            action: #selector( self.addSensorClicked( _: ) )
        )
        self.addSensorButton.bezelStyle = .rounded
        self.addSensorButton.controlSize = .small
        self.addSensorButton.isHidden = true
        root.addArrangedSubview( self.addSensorButton )

        self.curveUnavailableLabel = NSTextField(
            wrappingLabelWithString: "A selected temperature sensor is not available on this Mac."
        )
        self.curveUnavailableLabel.font = NSFont.systemFont( ofSize: 10 )
        self.curveUnavailableLabel.textColor = .secondaryLabelColor
        self.curveUnavailableLabel.isHidden = true
        self.curveUnavailableLabel.preferredMaxLayoutWidth = self.compact ? 320 : 400
        root.addArrangedSubview( self.curveUnavailableLabel )

        self.actionButton = NSButton(
            title: "Allow Fan Control…",
            target: self,
            action: #selector( self.actionClicked( _: ) )
        )
        self.actionButton.bezelStyle = .rounded
        self.actionButton.keyEquivalent = "\r"
        root.addArrangedSubview( self.actionButton )

        let safetyFull = "Manual and curve modes require a privileged helper (Login Items). Control restores to system automatic if Hot quits, sleeps, or the helper loses its heartbeat. The helper uses the highest cooling level across all sensor curves."
        let safety = NSTextField( wrappingLabelWithString: "Requires Login Items helper · restores to System if Hot quits." )
        safety.font = NSFont.systemFont( ofSize: 10 )
        safety.textColor = .tertiaryLabelColor
        safety.toolTip = safetyFull
        safety.preferredMaxLayoutWidth = self.compact ? 320 : 400
        root.addArrangedSubview( safety )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector( self.serviceUpdated( _: ) ),
            name: .fanControlDidUpdate,
            object: nil
        )
    }

    // MARK: - Preferences

    private func loadPreferences()
    {
        let defaults = UserDefaults.standard

        if let raw = defaults.string( forKey: FanControlDefaults.mode ),
           let mode = FanControlMode( rawValue: raw )
        {
            switch mode
            {
                case .system: self.modeControl.selectedSegment = 0
                case .manual: self.modeControl.selectedSegment = 1
                case .curve:  self.modeControl.selectedSegment = 2
            }
        }

        let level = defaults.integer( forKey: FanControlDefaults.coolingLevel )

        if FanControlPolicy.validCoolingLevel( level )
        {
            self.coolingLevel = level
        }
        else if defaults.object( forKey: FanControlDefaults.coolingLevel ) == nil
        {
            self.coolingLevel = FanControlPolicy.defaultCoolingLevel
        }

        self.intensitySlider.doubleValue = Double( self.coolingLevel )
        self.intensityLabel.stringValue  = "\( self.coolingLevel )%"

        if let stored = defaults.string( forKey: FanControlDefaults.curves ),
           let decoded = FanControlConfiguration.decodeCurves( stored )
        {
            self.curves = decoded
        }
        else
        {
            self.curves = [ FanControlConfiguration.defaultCurve ]
        }

        self.rebuildCurveEditors()
        self.updateModeVisibility()
    }

    private func savePreferences()
    {
        let defaults = UserDefaults.standard
        defaults.set( self.selectedMode().rawValue, forKey: FanControlDefaults.mode )
        defaults.set( self.coolingLevel, forKey: FanControlDefaults.coolingLevel )

        if let encoded = FanControlConfiguration.encodeCurves( self.curves )
        {
            defaults.set( encoded, forKey: FanControlDefaults.curves )
        }
    }

    // MARK: - Curve editors

    private func rebuildCurveEditors()
    {
        for view in self.curveEditors
        {
            self.curveListStack.removeArrangedSubview( view )
            view.removeFromSuperview()
        }

        self.curveEditors.removeAll()

        for index in self.curves.indices
        {
            let editor = FanControlCurveEditorView()
            editor.curveIndex = index
            editor.delegate = self
            editor.translatesAutoresizingMaskIntoConstraints = false
            self.curveListStack.addArrangedSubview( editor )
            editor.widthAnchor.constraint( equalTo: self.curveListStack.widthAnchor ).isActive = true
            self.curveEditors.append( editor )
        }

        self.refreshCurveEditors()
    }

    private func refreshCurveEditors()
    {
        let working = self.service.isWorking

        for ( index, editor ) in self.curveEditors.enumerated()
        {
            guard self.curves.indices.contains( index )
            else
            {
                continue
            }

            editor.configure(
                curve: self.curves[ index ],
                temperatures: self.temperatures,
                canRemoveCurve: self.curves.count > 1,
                availableSensors: self.sourceOptions( at: index ),
                disabled: working
            )
        }

        self.addSensorButton.isHidden = self.selectedMode() != .curve || self.nextAvailableSource() == nil
        self.addSensorButton.isEnabled = working == false
        self.curveUnavailableLabel.isHidden = self.selectedMode() != .curve || self.curveCanRun()
    }

    private func sourceOptions( at index: Int ) -> [ FanControlTemperatureSource ]
    {
        let current = self.curves[ index ].sensor
        let detected = Set( self.temperatures.map( \.source ) )
        let base = detected.isEmpty ? Set( FanControlTemperatureSource.allCases ) : detected
        let used = Set(
            self.curves.enumerated().compactMap
            {
                $0.offset == index ? nil : $0.element.sensor
            }
        )
        return FanControlTemperatureSource.allCases.filter
        {
            $0 == current || ( base.contains( $0 ) && used.contains( $0 ) == false )
        }
    }

    private func nextAvailableSource() -> FanControlTemperatureSource?
    {
        let used = Set( self.curves.map( \.sensor ) )
        let detected = Set( self.temperatures.map( \.source ) )
        let candidates = detected.isEmpty
            ? FanControlTemperatureSource.allCases
            : FanControlTemperatureSource.allCases.filter( detected.contains )
        return candidates.first { used.contains( $0 ) == false }
    }

    private func curveCanRun() -> Bool
    {
        guard FanControlPolicy.validCurves( self.curves )
        else
        {
            return false
        }

        let available = Set( self.temperatures.map( \.source ) )
        return available.isEmpty || self.curves.allSatisfy { available.contains( $0.sensor ) }
    }

    // MARK: - Actions

    @objc
    private func modeChanged( _ sender: Any? )
    {
        self.updateModeVisibility()
        self.savePreferences()
        self.updateActionTitle()
        self.refreshCurveEditors()
    }

    @objc
    private func intensityChanged( _ sender: Any? )
    {
        var level = Int( self.intensitySlider.doubleValue.rounded() )
        let step  = FanControlPolicy.coolingLevelStep
        level     = ( level / step ) * step
        level     = min( FanControlPolicy.maximumCoolingLevel, max( FanControlPolicy.minimumCoolingLevel, level ) )
        self.coolingLevel = level
        self.intensitySlider.doubleValue = Double( level )
        self.intensityLabel.stringValue  = "\( level )%"
        self.savePreferences()
    }

    @objc
    private func addSensorClicked( _ sender: Any? )
    {
        guard let source = self.nextAvailableSource()
        else
        {
            return
        }

        self.curves.append(
            FanControlCurve(
                sensor: source,
                points: FanControlConfiguration.defaultCurve.points
            )
        )
        self.rebuildCurveEditors()
        self.savePreferences()
        self.updateActionTitle()
    }

    @objc
    private func actionClicked( _ sender: Any? )
    {
        switch self.service.accessState
        {
            case .enabled:
                switch self.selectedMode()
                {
                    case .system:
                        self.service.restoreAutomatic()

                    case .manual:
                        self.service.applyConfiguration( .manual( level: self.coolingLevel ) )

                    case .curve:
                        guard self.curveCanRun()
                        else
                        {
                            self.refreshCurveEditors()
                            return
                        }
                        FanControlDiagnostics.leaveBreadcrumb( category: "ui", message: "apply_tapped", data: [ "mode": "curve" ] )
                        self.service.applyConfiguration( .curve( self.curves ) )
                }

            case .notRegistered, .requiresApproval, .unavailable, .unsupportedOS:
                self.service.authorize()
        }
    }

    @objc
    private func serviceUpdated( _ notification: Notification )
    {
        self.reloadFromService()
    }

    // MARK: - Display

    private func reloadFromService()
    {
        self.reloadRPMCards()
        self.reloadStatusPill()

        self.temperatures = self.service.snapshot.temperatures ?? []
        self.messageLabel.stringValue = self.stateMessage() ?? ""
        self.messageLabel.isHidden    = self.messageLabel.stringValue.isEmpty
        self.messageLabel.textColor   = self.service.error == nil ? .secondaryLabelColor : .systemRed

        self.modeControl.isEnabled     = self.service.isWorking == false
        self.intensitySlider.isEnabled = self.service.isWorking == false
        self.refreshCurveEditors()
        self.updateActionTitle()
        self.updateModeVisibility()
    }

    private func reloadRPMCards()
    {
        let fans = self.service.snapshot.fans

        for card in self.rpmCards
        {
            self.rpmStrip.removeArrangedSubview( card )
            card.removeFromSuperview()
        }
        self.rpmCards.removeAll()

        if fans.isEmpty
        {
            let placeholder = FanControlRPMCardView()
            placeholder.configurePlaceholder( "Waiting for fan readings…" )
            self.rpmStrip.addArrangedSubview( placeholder )
            self.rpmCards = [ placeholder ]

            DispatchQueue.global( qos: .utility ).async
            {
                [ weak self ] in
                let hasFans = FanControlHardware.hasControllableFan
                DispatchQueue.main.async
                {
                    [ weak self ] in
                    guard let self = self, self.service.snapshot.fans.isEmpty
                    else
                    {
                        return
                    }
                    self.rpmCards.first?.configurePlaceholder(
                        hasFans ? "Waiting for fan readings…" : "No controllable fans on this Mac."
                    )
                }
            }
            return
        }

        for fan in fans
        {
            let card = FanControlRPMCardView()
            card.configure( fan: fan )
            self.rpmStrip.addArrangedSubview( card )
            self.rpmCards.append( card )
        }
    }

    private func reloadStatusPill()
    {
        if self.service.snapshot.isCooling
        {
            let level = self.service.snapshot.coolingLevel ?? self.coolingLevel
            switch self.service.snapshot.configuration?.mode
            {
                case .manual:
                    self.statusPill.stringValue = "Manual · \( level )%"
                case .curve:
                    self.statusPill.stringValue = "Curve · \( level )%"
                default:
                    self.statusPill.stringValue = "Cooling · \( level )%"
            }
        }
        else
        {
            self.statusPill.stringValue = "System"
        }
    }

    private func stateMessage() -> String?
    {
        if self.service.accessState == .unsupportedOS
        {
            return "Fan control requires macOS 13 or later."
        }

        if self.service.clientMeetsCodeRequirement == false
        {
            return "This copy of Hot isn’t code-signed for the fan helper. Quit and open the signed app from /Applications."
        }

        if let error = self.service.error
        {
            switch error
            {
                case .noFans:                 return "No fans were found."
                case .unsupportedHardware:    return "This Mac’s fans cannot be controlled."
                case .alreadyControlled:      return "Another tool is already controlling the fans."
                case .authorizationRequired:  return "Allow Hot’s fan helper in Login Items."
                case .helperUnavailable:      return "The fan helper is unavailable. Try Allow Fan Control again."
                case .controlFailed:          return "Could not apply fan control. Restoring system control is safest."
            }
        }

        if self.service.snapshot.isCooling
        {
            return "Custom cooling is active. Heartbeat keeps it alive while Hot is running."
        }

        switch self.service.accessState
        {
            case .requiresApproval:
                return "Approve Hot in System Settings → Login Items, then return here."
            case .notRegistered:
                return "A one-time helper install is required before Manual or Curve modes work."
            default:
                return nil
        }
    }

    private func updateActionTitle()
    {
        if self.service.isWorking
        {
            self.actionButton.title = "Working…"
            self.actionButton.isEnabled = false
            return
        }

        self.actionButton.isEnabled = self.service.accessState != .unsupportedOS
            && self.service.clientMeetsCodeRequirement

        switch self.service.accessState
        {
            case .enabled:
                switch self.selectedMode()
                {
                    case .system: self.actionButton.title = "Use System Control"
                    case .manual: self.actionButton.title = "Apply Manual"
                    case .curve:  self.actionButton.title = "Apply Curve"
                }

            case .requiresApproval:
                self.actionButton.title = "Open Login Items…"

            case .unsupportedOS:
                self.actionButton.title = "Unsupported on this macOS"

            default:
                if self.service.clientMeetsCodeRequirement == false
                {
                    self.actionButton.title = "Open Signed Hot…"
                    self.actionButton.isEnabled = false
                }
                else
                {
                    self.actionButton.title = "Allow Fan Control…"
                }
        }

        if self.service.accessState == .enabled, self.selectedMode() == .curve
        {
            self.actionButton.isEnabled = self.curveCanRun() && self.service.isWorking == false
        }
    }

    private func updateModeVisibility()
    {
        let mode = self.selectedMode()
        self.manualStack.isHidden = mode != .manual
        self.curveScroll.isHidden = mode != .curve
        self.curveScrollHeightConstraint.isActive = mode == .curve
        self.addSensorButton.isHidden = mode != .curve || self.nextAvailableSource() == nil
        self.curveUnavailableLabel.isHidden = mode != .curve || self.curveCanRun()
    }

    private func selectedMode() -> FanControlMode
    {
        switch self.modeControl.selectedSegment
        {
            case 1:  return .manual
            case 2:  return .curve
            default: return .system
        }
    }
}


// MARK: - RPM card

final class FanControlRPMCardView: NSView
{
    private let iconView = NSImageView()
    private let nameLabel = NSTextField( labelWithString: "" )
    private let rpmLabel = NSTextField( labelWithString: "—" )
    private let unitLabel = NSTextField( labelWithString: "RPM" )
    private let targetLabel = NSTextField( labelWithString: "" )
    private let stack = NSStackView()
    private let rpmRow = NSStackView()

    override init( frame frameRect: NSRect )
    {
        super.init( frame: frameRect )
        self.build()
    }

    required init?( coder: NSCoder )
    {
        super.init( coder: coder )
        self.build()
    }

    func configure( fan: FanControlFanReading )
    {
        self.nameLabel.stringValue = "Fan \( fan.index + 1 )"
        self.nameLabel.textColor = .secondaryLabelColor
        self.rpmLabel.stringValue = "\( Int( fan.actualRPM.rounded() ) )"
        self.rpmRow.isHidden = false
        if fan.isManuallyControlled
        {
            self.targetLabel.stringValue = "→ \( Int( fan.targetRPM.rounded() ) )"
            self.targetLabel.isHidden = false
        }
        else
        {
            self.targetLabel.stringValue = ""
            self.targetLabel.isHidden = true
        }
        self.iconView.isHidden = false
        self.nameLabel.isHidden = false
    }

    func configurePlaceholder( _ text: String )
    {
        self.nameLabel.stringValue = text
        self.nameLabel.textColor = .secondaryLabelColor
        self.rpmLabel.stringValue = ""
        self.rpmRow.isHidden = true
        self.targetLabel.isHidden = true
        self.iconView.isHidden = true
    }

    private func build()
    {
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        self.stack.orientation = .vertical
        self.stack.alignment = .leading
        self.stack.spacing = 2
        self.stack.edgeInsets = NSEdgeInsets( top: 8, left: 10, bottom: 8, right: 10 )
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview( self.stack )
        NSLayoutConstraint.activate(
            [
                self.stack.leadingAnchor.constraint( equalTo: self.leadingAnchor ),
                self.stack.trailingAnchor.constraint( equalTo: self.trailingAnchor ),
                self.stack.topAnchor.constraint( equalTo: self.topAnchor ),
                self.stack.bottomAnchor.constraint( equalTo: self.bottomAnchor ),
            ]
        )

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4

        if #available( macOS 11.0, * )
        {
            let image = NSImage( systemSymbolName: "fanblades", accessibilityDescription: "Fan" )
                ?? NSImage( systemSymbolName: "wind", accessibilityDescription: "Fan" )
            self.iconView.image = image
            self.iconView.contentTintColor = .secondaryLabelColor
            self.iconView.symbolConfiguration = NSImage.SymbolConfiguration( pointSize: 10, weight: .medium )
        }
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.iconView.widthAnchor.constraint( equalToConstant: 12 ).isActive = true
        self.iconView.heightAnchor.constraint( equalToConstant: 12 ).isActive = true

        self.nameLabel.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.nameLabel.textColor = .secondaryLabelColor

        header.addArrangedSubview( self.iconView )
        header.addArrangedSubview( self.nameLabel )
        self.stack.addArrangedSubview( header )

        self.rpmRow.orientation = .horizontal
        self.rpmRow.alignment = .lastBaseline
        self.rpmRow.spacing = 3

        self.rpmLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 18, weight: .semibold )
        self.rpmLabel.textColor = .labelColor
        self.rpmLabel.setContentHuggingPriority( .required, for: .horizontal )

        self.unitLabel.font = NSFont.systemFont( ofSize: 9, weight: .medium )
        self.unitLabel.textColor = .tertiaryLabelColor

        self.rpmRow.addArrangedSubview( self.rpmLabel )
        self.rpmRow.addArrangedSubview( self.unitLabel )
        self.stack.addArrangedSubview( self.rpmRow )

        self.targetLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 9, weight: .regular )
        self.targetLabel.textColor = .tertiaryLabelColor
        self.targetLabel.isHidden = true
        self.stack.addArrangedSubview( self.targetLabel )

        self.setContentHuggingPriority( .defaultHigh, for: .horizontal )
        self.widthAnchor.constraint( greaterThanOrEqualToConstant: 88 ).isActive = true
    }
}


// MARK: - Window host

final class FanControlWindowController: NSWindowController, NSWindowDelegate
{
    private let panel = FanControlPanelController( compact: false )

    convenience init()
    {
        let window = NSWindow(
            contentRect: NSRect( x: 0, y: 0, width: 440, height: 420 ),
            styleMask: [ .titled, .closable, .miniaturizable, .resizable ],
            backing: .buffered,
            defer: false
        )
        window.title = "Fan Control"
        window.minSize = NSSize( width: 400, height: 360 )
        window.isReleasedWhenClosed = false
        window.center()

        self.init( window: window )
        self.window?.delegate = self
        window.contentViewController = self.panel
    }

    override func showWindow( _ sender: Any? )
    {
        super.showWindow( sender )
        self.panel.prepareForSidebarDisplay()
    }

    func windowWillClose( _ notification: Notification )
    {
        self.panel.prepareForSidebarHide()
    }
}

// MARK: - Curve editor delegate

extension FanControlPanelController: FanControlCurveEditorViewDelegate
{
    func curveEditor( _ editor: FanControlCurveEditorView, didChangeCurve curve: FanControlCurve )
    {
        let index = editor.curveIndex
        guard self.curves.indices.contains( index )
        else
        {
            return
        }

        self.curves[ index ] = curve
        self.savePreferences()
        self.refreshCurveEditors()
        self.updateActionTitle()
    }

    func curveEditorDidRequestRemove( _ editor: FanControlCurveEditorView )
    {
        let index = editor.curveIndex
        guard self.curves.count > 1, self.curves.indices.contains( index )
        else
        {
            return
        }

        self.curves.remove( at: index )
        self.rebuildCurveEditors()
        self.savePreferences()
        self.updateActionTitle()
    }
}

// MARK: - Per-sensor curve editor

protocol FanControlCurveEditorViewDelegate: AnyObject
{
    func curveEditor( _ editor: FanControlCurveEditorView, didChangeCurve curve: FanControlCurve )
    func curveEditorDidRequestRemove( _ editor: FanControlCurveEditorView )
}

final class FanControlCurveEditorView: NSView
{
    weak var delegate: FanControlCurveEditorViewDelegate?
    var curveIndex = 0

    private var curve = FanControlConfiguration.defaultCurve
    private var temperatures: [ FanControlTemperatureReading ] = []
    private var availableSensors: [ FanControlTemperatureSource ] = FanControlTemperatureSource.allCases

    private let sensorPopup = NSPopUpButton( frame: .zero, pullsDown: false )
    private let liveTempLabel = NSTextField( labelWithString: "" )
    private let removeCurveButton = NSButton( title: "−", target: nil, action: nil )
    private let graph = FanControlCurveView( frame: .zero )
    private let header = NSStackView()
    private let pointsStack = NSStackView()
    private let addPointButton = NSButton( title: "Add Point", target: nil, action: nil )
    private let root = NSStackView()
    private var pointRows: [ FanControlCurvePointRowView ] = []

    override init( frame frameRect: NSRect )
    {
        super.init( frame: frameRect )
        self.build()
    }

    required init?( coder: NSCoder )
    {
        super.init( coder: coder )
        self.build()
    }

    func configure(
        curve: FanControlCurve,
        temperatures: [ FanControlTemperatureReading ],
        canRemoveCurve: Bool,
        availableSensors: [ FanControlTemperatureSource ],
        disabled: Bool
    )
    {
        self.curve = curve
        self.temperatures = temperatures
        self.availableSensors = availableSensors

        self.sensorPopup.removeAllItems()
        for source in availableSensors
        {
            self.sensorPopup.addItem( withTitle: FanControlPolicy.displayName( for: source ) )
            self.sensorPopup.lastItem?.representedObject = source.rawValue
        }
        if let index = availableSensors.firstIndex( of: curve.sensor )
        {
            self.sensorPopup.selectItem( at: index )
        }

        if let reading = temperatures.first( where: { $0.source == curve.sensor } )
        {
            self.liveTempLabel.stringValue = String( format: "%.0f°C", reading.celsius )
            self.liveTempLabel.isHidden = false
        }
        else
        {
            self.liveTempLabel.stringValue = ""
            self.liveTempLabel.isHidden = true
        }

        self.removeCurveButton.isHidden = canRemoveCurve == false
        self.graph.points = curve.points
        self.graph.activeSensor = curve.sensor
        self.graph.temperatures = temperatures
        self.rebuildPointRows()

        self.sensorPopup.isEnabled = disabled == false
        self.removeCurveButton.isEnabled = disabled == false
        self.addPointButton.isEnabled = disabled == false
            && curve.points.count < FanControlPolicy.maximumCurvePointCount
            && FanControlPolicy.nextCurvePoint( for: curve.points ) != nil
        self.graph.isEnabled = disabled == false

        for row in self.pointRows
        {
            row.setEnabled( disabled == false )
        }
    }

    private func build()
    {
        self.root.orientation = .vertical
        self.root.alignment = .leading
        self.root.spacing = 8
        self.root.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview( self.root )
        NSLayoutConstraint.activate(
            [
                self.root.leadingAnchor.constraint( equalTo: self.leadingAnchor ),
                self.root.trailingAnchor.constraint( equalTo: self.trailingAnchor ),
                self.root.topAnchor.constraint( equalTo: self.topAnchor ),
                self.root.bottomAnchor.constraint( equalTo: self.bottomAnchor ),
            ]
        )

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        self.sensorPopup.target = self
        self.sensorPopup.action = #selector( self.sensorChanged( _: ) )
        self.sensorPopup.setContentHuggingPriority( .defaultHigh, for: .horizontal )

        self.liveTempLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 11, weight: .semibold )
        self.liveTempLabel.textColor = .secondaryLabelColor

        self.removeCurveButton.bezelStyle = .roundRect
        self.removeCurveButton.target = self
        self.removeCurveButton.action = #selector( self.removeCurveClicked( _: ) )
        self.removeCurveButton.toolTip = "Remove sensor"

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        top.addArrangedSubview( self.sensorPopup )
        top.addArrangedSubview( spacer )
        top.addArrangedSubview( self.liveTempLabel )
        top.addArrangedSubview( self.removeCurveButton )
        self.root.addArrangedSubview( top )
        top.widthAnchor.constraint( equalTo: self.root.widthAnchor ).isActive = true

        self.graph.translatesAutoresizingMaskIntoConstraints = false
        self.graph.heightAnchor.constraint( equalToConstant: 120 ).isActive = true
        self.graph.onChange =
        {
            [ weak self ] points in
            guard let self = self
            else
            {
                return
            }
            self.curve.points = points
            self.rebuildPointRows()
            self.delegate?.curveEditor( self, didChangeCurve: self.curve )
        }
        self.graph.onDragValueChange =
        {
            [ weak self ] index, point in
            self?.pointRows.enumerated().forEach
            {
                $0.element.setHighlighted( $0.offset == index )
                if $0.offset == index
                {
                    $0.element.update( point: point )
                }
            }
        }
        self.root.addArrangedSubview( self.graph )
        self.graph.widthAnchor.constraint( equalTo: self.root.widthAnchor ).isActive = true

        self.header.orientation = .horizontal
        self.header.spacing = 8
        let tempHeader = NSTextField( labelWithString: "Temperature" )
        tempHeader.font = NSFont.systemFont( ofSize: 10 )
        tempHeader.textColor = .secondaryLabelColor
        let speedHeader = NSTextField( labelWithString: "Fan speed" )
        speedHeader.font = NSFont.systemFont( ofSize: 10 )
        speedHeader.textColor = .secondaryLabelColor
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        self.header.addArrangedSubview( tempHeader )
        self.header.addArrangedSubview( headerSpacer )
        self.header.addArrangedSubview( speedHeader )
        let headerPad = NSView()
        headerPad.translatesAutoresizingMaskIntoConstraints = false
        self.header.addArrangedSubview( headerPad )
        headerPad.widthAnchor.constraint( equalToConstant: 28 ).isActive = true
        self.root.addArrangedSubview( self.header )
        self.header.widthAnchor.constraint( equalTo: self.root.widthAnchor ).isActive = true

        self.pointsStack.orientation = .vertical
        self.pointsStack.alignment = .leading
        self.pointsStack.spacing = 4
        self.root.addArrangedSubview( self.pointsStack )
        self.pointsStack.widthAnchor.constraint( equalTo: self.root.widthAnchor ).isActive = true

        self.addPointButton.bezelStyle = .rounded
        self.addPointButton.controlSize = .small
        self.addPointButton.target = self
        self.addPointButton.action = #selector( self.addPointClicked( _: ) )
        self.root.addArrangedSubview( self.addPointButton )
    }

    private func rebuildPointRows()
    {
        for row in self.pointRows
        {
            self.pointsStack.removeArrangedSubview( row )
            row.removeFromSuperview()
        }
        self.pointRows.removeAll()

        for index in self.curve.points.indices
        {
            let row = FanControlCurvePointRowView()
            row.pointIndex = index
            row.configure( point: self.curve.points[ index ], canRemove: self.curve.points.count > FanControlPolicy.minimumCurvePointCount )
            row.onChange =
            {
                [ weak self ] pointIndex, point in
                guard let self = self, self.curve.points.indices.contains( pointIndex )
                else
                {
                    return
                }
                self.curve.points[ pointIndex ] = self.clampedPoint( point, at: pointIndex )
                self.graph.points = self.curve.points
                self.pointRows[ pointIndex ].update( point: self.curve.points[ pointIndex ] )
                self.delegate?.curveEditor( self, didChangeCurve: self.curve )
            }
            row.onRemove =
            {
                [ weak self ] pointIndex in
                guard let self = self,
                      self.curve.points.count > FanControlPolicy.minimumCurvePointCount,
                      self.curve.points.indices.contains( pointIndex )
                else
                {
                    return
                }
                self.curve.points.remove( at: pointIndex )
                self.graph.points = self.curve.points
                self.rebuildPointRows()
                self.delegate?.curveEditor( self, didChangeCurve: self.curve )
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            self.pointsStack.addArrangedSubview( row )
            row.widthAnchor.constraint( equalTo: self.pointsStack.widthAnchor ).isActive = true
            self.pointRows.append( row )
        }

        self.addPointButton.isEnabled = self.curve.points.count < FanControlPolicy.maximumCurvePointCount
            && FanControlPolicy.nextCurvePoint( for: self.curve.points ) != nil
    }

    private func clampedPoint( _ point: FanControlCurvePoint, at index: Int ) -> FanControlCurvePoint
    {
        var temperature = point.temperature
        var level = point.coolingLevel

        if index > 0
        {
            temperature = max( temperature, self.curve.points[ index - 1 ].temperature + 1 )
            level = max( level, self.curve.points[ index - 1 ].coolingLevel )
        }
        if index + 1 < self.curve.points.count
        {
            temperature = min( temperature, self.curve.points[ index + 1 ].temperature - 1 )
            level = min( level, self.curve.points[ index + 1 ].coolingLevel )
        }

        temperature = min( FanControlPolicy.maximumCurveTemperature, max( FanControlPolicy.minimumCurveTemperature, temperature ) )
        level = min( FanControlPolicy.maximumCoolingLevel, max( FanControlPolicy.minimumCoolingLevel, level ) )
        level = ( level / FanControlPolicy.coolingLevelStep ) * FanControlPolicy.coolingLevelStep
        return FanControlCurvePoint( temperature: temperature, coolingLevel: level )
    }

    @objc
    private func sensorChanged( _ sender: Any? )
    {
        guard let raw = self.sensorPopup.selectedItem?.representedObject as? String,
              let sensor = FanControlTemperatureSource( rawValue: raw )
        else
        {
            return
        }
        self.curve.sensor = sensor
        self.delegate?.curveEditor( self, didChangeCurve: self.curve )
    }

    @objc
    private func removeCurveClicked( _ sender: Any? )
    {
        self.delegate?.curveEditorDidRequestRemove( self )
    }

    @objc
    private func addPointClicked( _ sender: Any? )
    {
        guard let updated = FanControlPolicy.addingCurvePoint( to: self.curve.points )
        else
        {
            return
        }
        self.curve.points = updated
        self.graph.points = updated
        self.rebuildPointRows()
        self.delegate?.curveEditor( self, didChangeCurve: self.curve )
    }
}

// MARK: - Point row

final class FanControlCurvePointRowView: NSView
{
    var pointIndex = 0
    var onChange: ( ( Int, FanControlCurvePoint ) -> Void )?
    var onRemove: ( ( Int ) -> Void )?

    private let temperatureLabel = NSTextField( labelWithString: "50°C" )
    private let temperatureStepper = NSStepper()
    private let levelLabel = NSTextField( labelWithString: "0%" )
    private let levelStepper = NSStepper()
    private let removeButton = NSButton( title: "×", target: nil, action: nil )
    private var point = FanControlCurvePoint( temperature: 50, coolingLevel: 0 )

    override init( frame frameRect: NSRect )
    {
        super.init( frame: frameRect )
        self.build()
    }

    required init?( coder: NSCoder )
    {
        super.init( coder: coder )
        self.build()
    }

    func configure( point: FanControlCurvePoint, canRemove: Bool )
    {
        self.point = point
        self.update( point: point )
        self.removeButton.isEnabled = canRemove
        self.removeButton.alphaValue = canRemove ? 1 : 0.35
    }

    func update( point: FanControlCurvePoint )
    {
        self.point = point
        self.temperatureLabel.stringValue = "\( point.temperature )°C"
        self.levelLabel.stringValue = "\( point.coolingLevel )%"
        self.temperatureStepper.integerValue = point.temperature
        self.levelStepper.integerValue = point.coolingLevel
    }

    func setEnabled( _ enabled: Bool )
    {
        self.temperatureStepper.isEnabled = enabled
        self.levelStepper.isEnabled = enabled
        self.removeButton.isEnabled = enabled && self.removeButton.alphaValue > 0.5
    }

    func setHighlighted( _ highlighted: Bool )
    {
        let accent: NSColor
        if #available( macOS 10.14, * )
        {
            accent = .controlAccentColor
        }
        else
        {
            accent = .selectedControlColor
        }

        self.temperatureLabel.textColor = highlighted ? accent : .labelColor
        self.levelLabel.textColor = highlighted ? accent : .labelColor
        self.temperatureLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: 11,
            weight: highlighted ? .bold : .regular
        )
        self.levelLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: 11,
            weight: highlighted ? .bold : .regular
        )
    }

    private func build()
    {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview( stack )
        NSLayoutConstraint.activate(
            [
                stack.leadingAnchor.constraint( equalTo: self.leadingAnchor ),
                stack.trailingAnchor.constraint( equalTo: self.trailingAnchor ),
                stack.topAnchor.constraint( equalTo: self.topAnchor ),
                stack.bottomAnchor.constraint( equalTo: self.bottomAnchor ),
            ]
        )

        self.temperatureLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 11, weight: .regular )
        self.temperatureLabel.alignment = .right
        self.temperatureLabel.translatesAutoresizingMaskIntoConstraints = false
        self.temperatureLabel.widthAnchor.constraint( equalToConstant: 48 ).isActive = true

        self.temperatureStepper.minValue = Double( FanControlPolicy.minimumCurveTemperature )
        self.temperatureStepper.maxValue = Double( FanControlPolicy.maximumCurveTemperature )
        self.temperatureStepper.increment = 1
        self.temperatureStepper.valueWraps = false
        self.temperatureStepper.target = self
        self.temperatureStepper.action = #selector( self.temperatureStepped( _: ) )

        let mid = NSView()
        mid.setContentHuggingPriority( .defaultLow, for: .horizontal )

        self.levelLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 11, weight: .regular )
        self.levelLabel.alignment = .right
        self.levelLabel.translatesAutoresizingMaskIntoConstraints = false
        self.levelLabel.widthAnchor.constraint( equalToConstant: 40 ).isActive = true

        self.levelStepper.minValue = Double( FanControlPolicy.minimumCoolingLevel )
        self.levelStepper.maxValue = Double( FanControlPolicy.maximumCoolingLevel )
        self.levelStepper.increment = Double( FanControlPolicy.coolingLevelStep )
        self.levelStepper.valueWraps = false
        self.levelStepper.target = self
        self.levelStepper.action = #selector( self.levelStepped( _: ) )

        self.removeButton.bezelStyle = .inline
        self.removeButton.target = self
        self.removeButton.action = #selector( self.removeClicked( _: ) )
        self.removeButton.toolTip = "Remove point"

        stack.addArrangedSubview( self.temperatureLabel )
        stack.addArrangedSubview( self.temperatureStepper )
        stack.addArrangedSubview( mid )
        stack.addArrangedSubview( self.levelLabel )
        stack.addArrangedSubview( self.levelStepper )
        stack.addArrangedSubview( self.removeButton )
    }

    @objc
    private func temperatureStepped( _ sender: Any? )
    {
        self.point.temperature = self.temperatureStepper.integerValue
        self.update( point: self.point )
        self.onChange?( self.pointIndex, self.point )
    }

    @objc
    private func levelStepped( _ sender: Any? )
    {
        self.point.coolingLevel = self.levelStepper.integerValue
        self.update( point: self.point )
        self.onChange?( self.pointIndex, self.point )
    }

    @objc
    private func removeClicked( _ sender: Any? )
    {
        self.onRemove?( self.pointIndex )
    }
}

// MARK: - Curve graph

final class FanControlCurveView: NSView
{
    var points: [ FanControlCurvePoint ] = FanControlConfiguration.defaultCurve.points
    {
        didSet
        {
            self.needsDisplay = true
        }
    }

    var temperatures: [ FanControlTemperatureReading ] = []
    {
        didSet
        {
            self.needsDisplay = true
        }
    }

    var activeSensor: FanControlTemperatureSource = .hottestSoC
    {
        didSet
        {
            self.needsDisplay = true
        }
    }

    var isEnabled = true
    var onChange: ( ( [ FanControlCurvePoint ] ) -> Void )?
    var onDragValueChange: ( ( Int, FanControlCurvePoint ) -> Void )?

    private var dragIndex: Int?
    private var hudText: String?

    override var isFlipped: Bool
    {
        true
    }

    override func draw( _ dirtyRect: NSRect )
    {
        let bounds = self.bounds.insetBy( dx: 8, dy: 8 )
        NSColor.controlBackgroundColor.setFill()
        let background = NSBezierPath( roundedRect: bounds, xRadius: 6, yRadius: 6 )
        background.fill()

        Self.gridColor.setStroke()
        for index in 0 ... 4
        {
            let y = bounds.minY + bounds.height * CGFloat( index ) / 4
            let grid = NSBezierPath()
            grid.move( to: NSPoint( x: bounds.minX, y: y ) )
            grid.line( to: NSPoint( x: bounds.maxX, y: y ) )
            grid.lineWidth = 0.5
            grid.stroke()
        }

        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        for ( index, point ) in self.points.enumerated()
        {
            let p = self.point( for: point, in: bounds )
            if index == 0
            {
                path.move( to: p )
            }
            else
            {
                path.line( to: p )
            }
        }

        Self.accentColor.setStroke()
        path.stroke()

        for ( index, point ) in self.points.enumerated()
        {
            let p = self.point( for: point, in: bounds )
            let size: CGFloat = self.dragIndex == index ? 12 : 9
            let dot = NSRect( x: p.x - size / 2, y: p.y - size / 2, width: size, height: size )
            Self.accentColor.setFill()
            NSBezierPath( ovalIn: dot ).fill()
            NSColor.white.withAlphaComponent( 0.9 ).setStroke()
            let ring = NSBezierPath( ovalIn: dot.insetBy( dx: 0.5, dy: 0.5 ) )
            ring.lineWidth = 1
            ring.stroke()
        }

        if let reading = self.temperatures.first( where: { $0.source == self.activeSensor } )
            ?? self.temperatures.first
        {
            let x = self.x( forTemperature: reading.celsius, in: bounds )
            NSColor.systemOrange.withAlphaComponent( 0.55 ).setStroke()
            let guide = NSBezierPath()
            guide.move( to: NSPoint( x: x, y: bounds.minY ) )
            guide.line( to: NSPoint( x: x, y: bounds.maxY ) )
            guide.stroke()
        }

        if let hudText = self.hudText, let index = self.dragIndex, self.points.indices.contains( index )
        {
            let p = self.point( for: self.points[ index ], in: bounds )
            let attrs: [ NSAttributedString.Key: Any ] = [
                .font: NSFont.monospacedDigitSystemFont( ofSize: 11, weight: .semibold ),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = ( hudText as NSString ).size( withAttributes: attrs )
            let box = NSRect(
                x: min( max( bounds.minX, p.x - size.width / 2 - 6 ), bounds.maxX - size.width - 12 ),
                y: max( bounds.minY, p.y - size.height - 18 ),
                width: size.width + 12,
                height: size.height + 6
            )
            NSColor.windowBackgroundColor.withAlphaComponent( 0.92 ).setFill()
            NSBezierPath( roundedRect: box, xRadius: 4, yRadius: 4 ).fill()
            ( hudText as NSString ).draw(
                at: NSPoint( x: box.minX + 6, y: box.minY + 3 ),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown( with event: NSEvent )
    {
        guard self.isEnabled
        else
        {
            return
        }

        let location = self.convert( event.locationInWindow, from: nil )
        let bounds   = self.bounds.insetBy( dx: 8, dy: 8 )
        var best: ( Int, CGFloat )?

        for ( index, point ) in self.points.enumerated()
        {
            let p = self.point( for: point, in: bounds )
            let d = hypot( p.x - location.x, p.y - location.y )
            if d < 14, d < ( best?.1 ?? .greatestFiniteMagnitude )
            {
                best = ( index, d )
            }
        }

        self.dragIndex = best?.0
        if let index = self.dragIndex
        {
            let point = self.points[ index ]
            self.hudText = "\( point.temperature )°C  ·  \( point.coolingLevel )%"
            self.onDragValueChange?( index, point )
            self.needsDisplay = true
        }
    }

    override func mouseDragged( with event: NSEvent )
    {
        guard self.isEnabled, let index = self.dragIndex
        else
        {
            return
        }

        let location = self.convert( event.locationInWindow, from: nil )
        let bounds   = self.bounds.insetBy( dx: 8, dy: 8 )
        var temperature = self.temperature( forX: location.x, in: bounds )
        var level = self.level( forY: location.y, in: bounds )

        if index > 0
        {
            temperature = max( temperature, self.points[ index - 1 ].temperature + 1 )
            level       = max( level, self.points[ index - 1 ].coolingLevel )
        }

        if index + 1 < self.points.count
        {
            temperature = min( temperature, self.points[ index + 1 ].temperature - 1 )
            level       = min( level, self.points[ index + 1 ].coolingLevel )
        }

        temperature = min( FanControlPolicy.maximumCurveTemperature, max( FanControlPolicy.minimumCurveTemperature, temperature ) )
        level       = min( FanControlPolicy.maximumCoolingLevel, max( FanControlPolicy.minimumCoolingLevel, level ) )
        level       = ( level / FanControlPolicy.coolingLevelStep ) * FanControlPolicy.coolingLevelStep

        let point = FanControlCurvePoint( temperature: temperature, coolingLevel: level )
        self.points[ index ] = point
        self.hudText = "\( temperature )°C  ·  \( level )%"
        self.onChange?( self.points )
        self.onDragValueChange?( index, point )
        self.needsDisplay = true
    }

    override func mouseUp( with event: NSEvent )
    {
        self.dragIndex = nil
        self.hudText = nil
        self.needsDisplay = true
    }

    private func point( for curvePoint: FanControlCurvePoint, in bounds: NSRect ) -> NSPoint
    {
        NSPoint(
            x: self.x( forTemperature: Double( curvePoint.temperature ), in: bounds ),
            y: self.y( forLevel: curvePoint.coolingLevel, in: bounds )
        )
    }

    private func x( forTemperature temperature: Double, in bounds: NSRect ) -> CGFloat
    {
        let minT = Double( FanControlPolicy.minimumCurveTemperature )
        let maxT = Double( FanControlPolicy.maximumCurveTemperature )
        let t = min( maxT, max( minT, temperature ) )
        return bounds.minX + CGFloat( ( t - minT ) / ( maxT - minT ) ) * bounds.width
    }

    private func y( forLevel level: Int, in bounds: NSRect ) -> CGFloat
    {
        let t = CGFloat( level ) / 100.0
        return bounds.maxY - t * bounds.height
    }

    private func temperature( forX x: CGFloat, in bounds: NSRect ) -> Int
    {
        let minT = Double( FanControlPolicy.minimumCurveTemperature )
        let maxT = Double( FanControlPolicy.maximumCurveTemperature )
        let t = Double( ( x - bounds.minX ) / bounds.width ) * ( maxT - minT ) + minT
        return Int( t.rounded() )
    }

    private func level( forY y: CGFloat, in bounds: NSRect ) -> Int
    {
        let t = Double( ( bounds.maxY - y ) / bounds.height ) * 100.0
        return Int( t.rounded() )
    }

    private static var gridColor: NSColor
    {
        if #available( macOS 10.14, * )
        {
            return NSColor.separatorColor.withAlphaComponent( 0.45 )
        }
        return NSColor( white: 0.75, alpha: 0.45 )
    }

    private static var accentColor: NSColor
    {
        if #available( macOS 10.14, * )
        {
            return .controlAccentColor
        }
        return .selectedControlColor
    }
}
