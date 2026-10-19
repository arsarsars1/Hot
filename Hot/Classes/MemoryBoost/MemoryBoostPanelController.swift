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

/// Compact status-menu sidebar: processes by RAM + Dev-ports Stop All.
final class MemoryBoostPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate
{
    private static let panelWidth: CGFloat  = 340
    private static let panelHeight: CGFloat = 420
    /// Initial paint budget; Show more steps up (virtualized table can hold the full list).
    private static let initialVisibleLimit = 48
    private static let visibleStep         = 48
    private static let appRowHeight: CGFloat = 44
    private static let appsColumnID = NSUserInterfaceItemIdentifier( "hot.memoryBoost.app" )
    private static let appsCellID   = NSUserInterfaceItemIdentifier( "hot.memoryBoost.appCell" )

    private let appService  = AppProcessService.shared
    private let portService = DevPortStopService.shared

    /// Called when the user taps Hide — collapses the Memory Boost sidebar.
    var onRequestCollapse: ( () -> Void )?

    private var appsTable:            NSTableView!
    private var appsPlaceholderStack: NSStackView!
    private var listenersStack:       NSStackView!
    private var appsCountPill:        NSTextField!
    private var portsCountPill:       NSTextField!
    private var appsShowingLabel:     NSTextField!
    private var showMoreButton:       NSButton!
    private var appsFooter:           NSStackView!
    private var statusLabel:          NSTextField!
    private var statusSpinner:        NSProgressIndicator!
    private var stopPortsButton:      NSButton!
    private var appsScroll:           NSScrollView!
    private var portsScroll:          NSScrollView!
    private var contentStack:         NSStackView!
    private var contentHeightConstraint: NSLayoutConstraint?
    private var listsCollapsed   = false
    private var refreshTimer:    Timer?
    private var apps:            [ AppProcessInfo ] = []
    /// Rows currently exposed in the table (prefix of `apps` up to `visibleProcessLimit`).
    private var visibleApps:     [ AppProcessInfo ] = []
    private var visibleProcessLimit = MemoryBoostPanelController.initialVisibleLimit
    private var listeners:       [ DevPortListener ] = []
    private var isPresented      = false
    private var isBusy           = false
    /// True while an open-path / cold list refresh is in flight (skeletons + status pill).
    private var refreshInFlight  = false
    private var collapseListsButton: NSButton!
    /// Icons keyed by bundle ID or `pid:<n>`; resolved once, not every refresh.
    private var iconByCacheKey:  [ String: NSImage ] = [:]
    /// Keys whose cached image is an SF Symbol placeholder (tint on image view).
    private var symbolIconKeys:  Set<String> = []
    private var showingAppSkeletons = false

    override func loadView()
    {
        let root = NSView( frame: NSRect( x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight ) )
        root.wantsLayer = true
        self.view = root
        self.buildUI()
    }

    deinit
    {
        self.refreshTimer?.invalidate()
    }

    func prepareForSidebarDisplay()
    {
        self.isPresented = true
        self.refreshInFlight = true

        // Cache-first: paint last snapshot immediately; never wait on main for a scan.
        // Sidebar width animation must not wait on data (skeletons / Updating only).
        if let appSnap = self.appService.cachedSnapshot
        {
            self.apps = appSnap.apps
            self.applyAppRows()
            self.setListStatus( .updating )
        }
        else
        {
            self.apps = []
            self.applyAppRows()
            self.setListStatus( .scanning )
        }

        if let portSnap = self.portService.cachedSnapshot
        {
            self.listeners = portSnap.listeners
            self.rebuildListenerRows()
        }

        self.applyListsCollapsedVisibility()
        self.reloadAll( forceRefresh: true )
        self.startRefreshTimer()
    }

    func prepareForSidebarHide()
    {
        self.isPresented = false
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        // Next open starts light again (top-N); Show more re-expands as needed.
        self.visibleProcessLimit = Self.initialVisibleLimit
        // Closed-cadence warmer on AppProcessService keeps running.
    }

    // MARK: - UI

    private func buildUI()
    {
        let content = self.view
        let inset: CGFloat = 12
        let spacing: CGFloat = 10

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
                root.bottomAnchor.constraint( equalTo: content.bottomAnchor ),
            ]
        )

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
        accent.heightAnchor.constraint( equalToConstant: 16 ).isActive = true
        titleRow.addArrangedSubview( accent )

        let title = NSTextField( labelWithString: "Memory Boost" )
        title.font = NSFont.systemFont( ofSize: 14, weight: .semibold )
        titleRow.addArrangedSubview( title )

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        titleRow.addArrangedSubview( titleSpacer )

        self.collapseListsButton = NSButton(
            title: "▾ Lists",
            target: self,
            action: #selector( self.toggleListsCollapsed( _: ) )
        )
        self.collapseListsButton.bezelStyle = .recessed
        self.collapseListsButton.controlSize = .small
        self.collapseListsButton.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.collapseListsButton.toolTip = "Show or hide the apps and Dev-ports lists"
        titleRow.addArrangedSubview( self.collapseListsButton )

        let hideButton = NSButton(
            title: "Hide",
            target: self,
            action: #selector( self.hideSidebar( _: ) )
        )
        hideButton.bezelStyle = .recessed
        hideButton.controlSize = .small
        hideButton.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        hideButton.toolTip = "Collapse Memory Boost sidebar"
        titleRow.addArrangedSubview( hideButton )

        root.addArrangedSubview( titleRow )
        titleRow.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let subtitle = NSTextField( labelWithString: "All processes · RAM high → low" )
        subtitle.font = NSFont.systemFont( ofSize: 10, weight: .regular )
        subtitle.textColor = .tertiaryLabelColor
        root.addArrangedSubview( subtitle )

        self.contentStack = NSStackView()
        self.contentStack.orientation = .vertical
        self.contentStack.alignment = .leading
        self.contentStack.spacing = spacing
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview( self.contentStack )
        self.contentStack.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true
        self.contentStack.setContentHuggingPriority( .defaultLow, for: .vertical )
        self.contentStack.setContentCompressionResistancePriority( .defaultLow, for: .vertical )

        let ( appsHeader, appsPill ) = self.makeSectionHeader( title: "Processes", detail: "RAM ↓" )
        self.appsCountPill = appsPill
        self.contentStack.addArrangedSubview( appsHeader )

        let appsHost = self.makeAppsListHost( height: 200 )
        self.contentStack.addArrangedSubview( appsHost )
        appsHost.widthAnchor.constraint( equalTo: self.contentStack.widthAnchor ).isActive = true

        self.appsFooter = NSStackView()
        self.appsFooter.orientation = .horizontal
        self.appsFooter.alignment = .centerY
        self.appsFooter.spacing = 8
        self.appsFooter.translatesAutoresizingMaskIntoConstraints = false

        self.appsShowingLabel = NSTextField( labelWithString: "" )
        self.appsShowingLabel.font = NSFont.systemFont( ofSize: 9, weight: .medium )
        self.appsShowingLabel.textColor = .tertiaryLabelColor
        self.appsFooter.addArrangedSubview( self.appsShowingLabel )

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        self.appsFooter.addArrangedSubview( footerSpacer )

        self.showMoreButton = NSButton(
            title: "Show more",
            target: self,
            action: #selector( self.showMoreApps( _: ) )
        )
        self.showMoreButton.bezelStyle = .recessed
        self.showMoreButton.controlSize = .small
        self.showMoreButton.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.showMoreButton.toolTip = "Reveal more processes by RAM (list is virtualized)"
        self.showMoreButton.isHidden = true
        self.appsFooter.addArrangedSubview( self.showMoreButton )

        self.contentStack.addArrangedSubview( self.appsFooter )
        self.appsFooter.widthAnchor.constraint( equalTo: self.contentStack.widthAnchor ).isActive = true

        let quitHint = NSTextField( labelWithString: "⌥-click Quit to Force Quit · helpers use signal" )
        quitHint.font = NSFont.systemFont( ofSize: 9, weight: .medium )
        quitHint.textColor = .tertiaryLabelColor
        self.contentStack.addArrangedSubview( quitHint )

        self.contentStack.addArrangedSubview( self.makeHairline() )

        let ( portsHeader, portsPill ) = self.makeSectionHeader(
            title: "Dev ports",
            detail: "3000–3002 · 5173–5176 · 5199"
        )
        self.portsCountPill = portsPill
        self.contentStack.addArrangedSubview( portsHeader )

        self.listenersStack = NSStackView()
        self.listenersStack.orientation = .vertical
        self.listenersStack.alignment = .width
        self.listenersStack.spacing = 4
        self.listenersStack.translatesAutoresizingMaskIntoConstraints = false

        self.portsScroll = self.makeScrollHost( documentStack: self.listenersStack, height: 100 )
        self.contentStack.addArrangedSubview( self.portsScroll )
        self.portsScroll.widthAnchor.constraint( equalTo: self.contentStack.widthAnchor ).isActive = true

        let stopRow = NSStackView()
        stopRow.orientation = .horizontal
        stopRow.alignment = .centerY
        stopRow.spacing = 8

        self.stopPortsButton = NSButton(
            title: "Stop all listeners",
            target: self,
            action: #selector( self.stopAllListeners( _: ) )
        )
        self.stopPortsButton.bezelStyle = .rounded
        self.stopPortsButton.controlSize = .small
        self.stopPortsButton.font = NSFont.systemFont( ofSize: 11, weight: .medium )
        self.stopPortsButton.toolTip =
            "Quits the processes listening on Dev ports (SIGTERM / app Quit), which frees those ports. Does not touch other ports."
        stopRow.addArrangedSubview( self.stopPortsButton )

        let stopSpacer = NSView()
        stopSpacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        stopRow.addArrangedSubview( stopSpacer )
        self.contentStack.addArrangedSubview( stopRow )
        stopRow.widthAnchor.constraint( equalTo: self.contentStack.widthAnchor ).isActive = true

        let portsHint = NSTextField(
            wrappingLabelWithString: "Stops those processes (not only the sockets) so Dev ports are free again."
        )
        portsHint.font = NSFont.systemFont( ofSize: 9 )
        portsHint.textColor = .tertiaryLabelColor
        portsHint.preferredMaxLayoutWidth = 300
        self.contentStack.addArrangedSubview( portsHint )

        self.statusLabel = NSTextField( labelWithString: "Ready" )
        self.statusLabel.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.statusLabel.textColor = .secondaryLabelColor
        self.statusLabel.maximumNumberOfLines = 2
        self.statusLabel.preferredMaxLayoutWidth = 280
        self.statusLabel.setContentHuggingPriority( .required, for: .vertical )
        self.statusLabel.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        self.statusSpinner = NSProgressIndicator()
        self.statusSpinner.style = .spinning
        self.statusSpinner.controlSize = .small
        self.statusSpinner.isDisplayedWhenStopped = false
        self.statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        self.statusSpinner.widthAnchor.constraint( equalToConstant: 12 ).isActive = true
        self.statusSpinner.heightAnchor.constraint( equalToConstant: 12 ).isActive = true

        root.addArrangedSubview( self.makeStatusPill() )
    }

    @objc
    private func hideSidebar( _ sender: Any? )
    {
        self.onRequestCollapse?()
    }

    @objc
    private func toggleListsCollapsed( _ sender: Any? )
    {
        self.listsCollapsed.toggle()
        self.collapseListsButton.title = self.listsCollapsed ? "▸ Lists" : "▾ Lists"

        if self.listsCollapsed
        {
            // Capture current height, then hide children while keeping the slot.
            self.contentStack.layoutSubtreeIfNeeded()
            let kept = max( self.contentStack.fittingSize.height, 280 )
            self.contentHeightConstraint?.isActive = false
            let height = self.contentStack.heightAnchor.constraint( equalToConstant: kept )
            height.priority = .required
            height.isActive = true
            self.contentHeightConstraint = height
            self.contentStack.arrangedSubviews.forEach { $0.isHidden = true }
            self.contentStack.alphaValue = 0
        }
        else
        {
            self.contentHeightConstraint?.isActive = false
            self.contentHeightConstraint = nil
            self.contentStack.arrangedSubviews.forEach { $0.isHidden = false }
            self.contentStack.alphaValue = 1
        }

        // Geometry is pinned on the root — do not let the menu reflow smaller.
        self.view.frame.size = NSSize( width: Self.panelWidth, height: Self.panelHeight )
        self.view.needsLayout = true
        if let menu = self.view.enclosingMenuItem?.menu
        {
            menu.itemChanged( self.view.enclosingMenuItem! )
        }
    }

    private func makeSectionHeader( title: String, detail: String ) -> ( NSView, NSTextField )
    {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let label = NSTextField( labelWithString: title )
        label.font = NSFont.systemFont( ofSize: 11, weight: .semibold )
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview( label )

        let detailLabel = NSTextField( labelWithString: detail )
        detailLabel.font = NSFont.systemFont( ofSize: 10, weight: .regular )
        detailLabel.textColor = .tertiaryLabelColor
        row.addArrangedSubview( detailLabel )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( spacer )

        let count = NSTextField( labelWithString: "0" )
        count.font = NSFont.monospacedDigitSystemFont( ofSize: 10, weight: .medium )
        count.textColor = .secondaryLabelColor
        count.alignment = .center
        count.drawsBackground = false
        count.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 7
        wrap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.06 ).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview( count )
        NSLayoutConstraint.activate(
            [
                count.leadingAnchor.constraint( equalTo: wrap.leadingAnchor, constant: 7 ),
                count.trailingAnchor.constraint( equalTo: wrap.trailingAnchor, constant: -7 ),
                count.topAnchor.constraint( equalTo: wrap.topAnchor, constant: 2 ),
                count.bottomAnchor.constraint( equalTo: wrap.bottomAnchor, constant: -2 ),
            ]
        )
        row.addArrangedSubview( wrap )

        return ( row, count )
    }

    private func makeHairline() -> NSView
    {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint( equalToConstant: 1 ).isActive = true
        if #available( macOS 10.14, * )
        {
            line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        else
        {
            line.layer?.backgroundColor = NSColor( white: 0.75, alpha: 0.55 ).cgColor
        }
        return line
    }

    /// Scroll view with the stack as documentView — sized via contentView width pin.
    private func makeScrollHost( documentStack: NSStackView, height: CGFloat ) -> NSScrollView
    {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.045 ).cgColor
        scroll.documentView = documentStack
        scroll.heightAnchor.constraint( equalToConstant: height ).isActive = true

        documentStack.translatesAutoresizingMaskIntoConstraints = false
        // Width tracks the visible content view so rows stay full-width.
        if let contentView = scroll.contentView as NSClipView?
        {
            documentStack.widthAnchor.constraint( equalTo: contentView.widthAnchor, constant: -12 ).isActive = true
            documentStack.leadingAnchor.constraint( equalTo: contentView.leadingAnchor, constant: 6 ).isActive = true
            documentStack.topAnchor.constraint( equalTo: contentView.topAnchor, constant: 6 ).isActive = true
        }

        return scroll
    }

    /// Virtualized apps list: view-based `NSTableView` + overlay for skeletons / empty.
    private func makeAppsListHost( height: CGFloat ) -> NSView
    {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.cornerRadius = 8
        host.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.045 ).cgColor
        host.heightAnchor.constraint( equalToConstant: height ).isActive = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.focusRingType = .none

        let table = NSTableView()
        table.headerView = nil
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = Self.appRowHeight
        table.intercellSpacing = NSSize( width: 0, height: 4 )
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self

        let column = NSTableColumn( identifier: Self.appsColumnID )
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        table.addTableColumn( column )
        table.sizeLastColumnToFit()

        scroll.documentView = table
        self.appsTable = table
        self.appsScroll = scroll

        self.appsPlaceholderStack = NSStackView()
        self.appsPlaceholderStack.orientation = .vertical
        self.appsPlaceholderStack.alignment = .width
        self.appsPlaceholderStack.spacing = 4
        self.appsPlaceholderStack.edgeInsets = NSEdgeInsets( top: 6, left: 6, bottom: 6, right: 6 )
        self.appsPlaceholderStack.translatesAutoresizingMaskIntoConstraints = false
        self.appsPlaceholderStack.isHidden = true

        host.addSubview( scroll )
        host.addSubview( self.appsPlaceholderStack )
        NSLayoutConstraint.activate(
            [
                scroll.leadingAnchor.constraint( equalTo: host.leadingAnchor ),
                scroll.trailingAnchor.constraint( equalTo: host.trailingAnchor ),
                scroll.topAnchor.constraint( equalTo: host.topAnchor ),
                scroll.bottomAnchor.constraint( equalTo: host.bottomAnchor ),
                self.appsPlaceholderStack.leadingAnchor.constraint( equalTo: host.leadingAnchor ),
                self.appsPlaceholderStack.trailingAnchor.constraint( equalTo: host.trailingAnchor ),
                self.appsPlaceholderStack.topAnchor.constraint( equalTo: host.topAnchor ),
                self.appsPlaceholderStack.bottomAnchor.constraint( lessThanOrEqualTo: host.bottomAnchor ),
            ]
        )

        return host
    }

    private func makeStatusPill() -> NSView
    {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview( self.statusSpinner )
        row.addArrangedSubview( self.statusLabel )

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 8
        wrap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.05 ).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview( row )
        NSLayoutConstraint.activate(
            [
                row.leadingAnchor.constraint( equalTo: wrap.leadingAnchor, constant: 8 ),
                row.trailingAnchor.constraint( equalTo: wrap.trailingAnchor, constant: -8 ),
                row.topAnchor.constraint( equalTo: wrap.topAnchor, constant: 5 ),
                row.bottomAnchor.constraint( equalTo: wrap.bottomAnchor, constant: -5 ),
                wrap.widthAnchor.constraint( equalToConstant: 316 ),
            ]
        )
        return wrap
    }

    private enum ListStatus
    {
        case ready
        case scanning
        case updating
    }

    private func setListStatus( _ status: ListStatus )
    {
        switch status
        {
            case .ready:
                self.statusLabel.stringValue = "Ready"
                self.statusSpinner.stopAnimation( nil )

            case .scanning:
                self.statusLabel.stringValue = "Scanning processes…"
                self.statusSpinner.startAnimation( nil )

            case .updating:
                self.statusLabel.stringValue = "Updating…"
                self.statusSpinner.startAnimation( nil )
        }
    }

    private func isListLoadingStatus( _ value: String ) -> Bool
    {
        value == "Updating…" || value == "Scanning processes…"
    }

    private func makeCardRow( emphasized: Bool = false ) -> NSStackView
    {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets( top: 7, left: 8, bottom: 7, right: 8 )
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        if emphasized
        {
            row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent( 0.12 ).cgColor
            row.layer?.borderWidth = 1
            row.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent( 0.22 ).cgColor
        }
        else
        {
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent( 0.9 ).cgColor
            row.layer?.borderWidth = 1
            row.layer?.borderColor = NSColor.labelColor.withAlphaComponent( 0.06 ).cgColor
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Refresh

    private func startRefreshTimer()
    {
        self.refreshTimer?.invalidate()
        let timer = Timer( timeInterval: AppProcessService.openMaxAge, repeats: true )
        {
            [ weak self ] _ in
            self?.reloadAll( forceRefresh: false )
        }
        RunLoop.main.add( timer, forMode: .common )
        self.refreshTimer = timer
    }

    /// Apply cached / refreshed snapshots. `forceRefresh` bypasses maxAge (open + post-quit).
    private func reloadAll( forceRefresh: Bool )
    {
        guard self.isPresented, self.isBusy == false
        else
        {
            return
        }

        let appMaxAge  = forceRefresh ? 0 : AppProcessService.openMaxAge
        let portMaxAge = forceRefresh ? 0 : DevPortStopService.openMaxAge

        var pendingApps: [ AppProcessInfo ]?
        var pendingListeners: [ DevPortListener ]?
        let gate = DispatchQueue( label: "hot.memoryBoost.reloadGate" )

        let applyIfReady: () -> Void =
        {
            [ weak self ] in
            gate.async
            {
                guard let apps = pendingApps, let listeners = pendingListeners
                else
                {
                    return
                }

                DispatchQueue.main.async
                {
                    [ weak self ] in
                    guard let self = self, self.isPresented, self.isBusy == false
                    else
                    {
                        return
                    }

                    self.refreshInFlight = false

                    // Skip UI work when content is unchanged (open cadence ~3s).
                    let appsUnchanged = apps == self.apps
                    let listenersUnchanged = listeners == self.listeners

                    if appsUnchanged == false
                    {
                        self.apps = apps
                        self.applyAppRows()
                    }

                    if listenersUnchanged == false
                    {
                        self.listeners = listeners
                        self.rebuildListenerRows()
                    }

                    self.applyListsCollapsedVisibility()
                    if self.isListLoadingStatus( self.statusLabel.stringValue )
                    {
                        self.setListStatus( .ready )
                    }
                }
            }
        }

        self.appService.refreshIfNeeded( maxAge: appMaxAge )
        {
            snap in
            gate.async
            {
                pendingApps = snap.apps
                applyIfReady()
            }
        }

        self.portService.refreshIfNeeded( maxAge: portMaxAge )
        {
            snap in
            gate.async
            {
                pendingListeners = snap.listeners
                applyIfReady()
            }
        }
    }

    private func applyListsCollapsedVisibility()
    {
        guard self.listsCollapsed
        else
        {
            return
        }

        self.contentStack.arrangedSubviews.forEach { $0.isHidden = true }
        self.contentStack.alphaValue = 0
    }

    private func clearStack( _ stack: NSStackView )
    {
        stack.arrangedSubviews.forEach
        {
            stack.removeArrangedSubview( $0 )
            $0.removeFromSuperview()
        }
    }

    /// Diff-apply visible prefix by PID into the virtualized table; pill shows total scanned.
    private func applyAppRows()
    {
        self.appsCountPill.stringValue = "\( self.apps.count )"

        if self.apps.isEmpty
        {
            self.visibleApps = []
            self.appsTable.reloadData()
            self.showAppsPlaceholder()
            self.updateShowMoreFooter()
            return
        }

        self.hideAppsPlaceholder()

        // Keep an expanded limit if the user already asked for more, but never above the scan.
        if self.visibleProcessLimit > self.apps.count
        {
            self.visibleProcessLimit = max( Self.initialVisibleLimit, self.apps.count )
        }

        let next = Array( self.apps.prefix( self.visibleProcessLimit ) )
        let sameIdentity = next.map( \.pid ) == self.visibleApps.map( \.pid )

        if sameIdentity, next.isEmpty == false
        {
            self.visibleApps = next
            let rows = IndexSet( integersIn: 0 ..< self.visibleApps.count )
            self.appsTable.reloadData( forRowIndexes: rows, columnIndexes: IndexSet( integer: 0 ) )
        }
        else
        {
            self.visibleApps = next
            self.appsTable.reloadData()
        }

        self.updateShowMoreFooter()
    }

    private func showAppsPlaceholder()
    {
        self.clearStack( self.appsPlaceholderStack )
        self.showingAppSkeletons = false
        self.appsScroll.isHidden = true
        self.appsPlaceholderStack.isHidden = false

        if self.refreshInFlight
        {
            self.appsCountPill.stringValue = "…"
            self.showingAppSkeletons = true
            for _ in 0 ..< 4
            {
                self.appsPlaceholderStack.addArrangedSubview( self.makeSkeletonAppRow() )
            }
        }
        else
        {
            let empty = NSTextField( labelWithString: "No processes to list" )
            empty.font = NSFont.systemFont( ofSize: 11 )
            empty.textColor = .tertiaryLabelColor
            self.appsPlaceholderStack.addArrangedSubview( empty )
        }
    }

    private func hideAppsPlaceholder()
    {
        if self.showingAppSkeletons || self.appsPlaceholderStack.isHidden == false
        {
            self.clearStack( self.appsPlaceholderStack )
            self.showingAppSkeletons = false
            self.appsPlaceholderStack.isHidden = true
        }
        self.appsScroll.isHidden = false
    }

    private func updateShowMoreFooter()
    {
        let showing = self.visibleApps.count
        let total = self.apps.count

        if total == 0
        {
            self.appsShowingLabel.stringValue = ""
            self.appsFooter.isHidden = true
            return
        }

        self.appsFooter.isHidden = false
        self.appsShowingLabel.stringValue = "Showing \( showing ) of \( total )"

        let canShowMore = showing < total
        self.showMoreButton.isHidden = canShowMore == false
        if canShowMore
        {
            let nextCount = min( showing + Self.visibleStep, total )
            self.showMoreButton.title = nextCount >= total
                ? "Show all (\( total ))"
                : "Show more"
        }
    }

    /// Muted placeholder cards shown while `apps.isEmpty && refreshInFlight`.
    private func makeSkeletonAppRow() -> NSView
    {
        let row = self.makeCardRow()
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.04 ).cgColor
        row.layer?.borderColor = NSColor.labelColor.withAlphaComponent( 0.04 ).cgColor

        let bone: ( CGFloat, CGFloat ) -> NSView =
        {
            width, height in
            let view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = height / 2
            view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.08 ).cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint( equalToConstant: width ).isActive = true
            view.heightAnchor.constraint( equalToConstant: height ).isActive = true
            return view
        }

        row.addArrangedSubview( bone( 18, 10 ) )

        let icon = NSView()
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 5
        icon.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.08 ).cgColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint( equalToConstant: 24 ).isActive = true
        icon.heightAnchor.constraint( equalToConstant: 24 ).isActive = true
        row.addArrangedSubview( icon )

        let nameCol = NSStackView()
        nameCol.orientation = .vertical
        nameCol.alignment = .leading
        nameCol.spacing = 4
        nameCol.addArrangedSubview( bone( 120, 10 ) )
        nameCol.addArrangedSubview( bone( 72, 8 ) )
        row.addArrangedSubview( nameCol )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( spacer )

        row.addArrangedSubview( bone( 52, 16 ) )
        row.addArrangedSubview( bone( 36, 16 ) )

        return row
    }

    private func bindAppRow( _ row: AppProcessRowView, app: AppProcessInfo, rank: Int )
    {
        row.quitButton.target = self
        row.quitButton.action = #selector( self.quitApp( _: ) )
        let resolved = self.cachedIcon( for: app )
        row.iconView.image = resolved.image
        if resolved.isSymbol
        {
            row.iconView.contentTintColor = .secondaryLabelColor
        }
        else
        {
            row.iconView.contentTintColor = nil
        }
        row.update( app: app, rank: rank )
    }

    // MARK: - NSTableView

    func numberOfRows( in tableView: NSTableView ) -> Int
    {
        tableView === self.appsTable ? self.visibleApps.count : 0
    }

    func tableView( _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int ) -> NSView?
    {
        guard tableView === self.appsTable, row >= 0, row < self.visibleApps.count
        else
        {
            return nil
        }

        let app = self.visibleApps[ row ]
        let cell: AppProcessRowView
        if let reused = tableView.makeView( withIdentifier: Self.appsCellID, owner: self ) as? AppProcessRowView
        {
            cell = reused
        }
        else
        {
            cell = AppProcessRowView()
            cell.identifier = Self.appsCellID
            // Table view owns the cell frame; keep autoresizing for column width.
            cell.translatesAutoresizingMaskIntoConstraints = true
            cell.autoresizingMask = [ .width ]
        }

        self.bindAppRow( cell, app: app, rank: row + 1 )
        return cell
    }

    func tableView( _ tableView: NSTableView, heightOfRow row: Int ) -> CGFloat
    {
        Self.appRowHeight
    }

    func tableView( _ tableView: NSTableView, shouldSelectRow row: Int ) -> Bool
    {
        false
    }

    /// Resolve icon once per bundle / PID; SF Symbol placeholders when no app icon.
    private func cachedIcon( for app: AppProcessInfo ) -> ( image: NSImage?, isSymbol: Bool )
    {
        let key = app.bundleIdentifier ?? "pid:\( app.pid )"
        if let cached = self.iconByCacheKey[ key ]
        {
            return ( cached, self.symbolIconKeys.contains( key ) )
        }

        var image: NSImage?
        var isSymbol = false
        if let running = NSRunningApplication( processIdentifier: app.pid ),
           let icon = running.icon
        {
            image = icon
        }
        else if #available( macOS 11.0, * )
        {
            let symbol = app.isRegularApp ? "app.fill" : "gearshape.2.fill"
            image = NSImage( systemSymbolName: symbol, accessibilityDescription: nil )
            isSymbol = image != nil
        }

        if let image = image
        {
            self.iconByCacheKey[ key ] = image
            if isSymbol
            {
                self.symbolIconKeys.insert( key )
            }
        }

        return ( image, isSymbol )
    }

    private func rebuildListenerRows()
    {
        self.clearStack( self.listenersStack )
        self.portsCountPill.stringValue = "\( self.listeners.count )"
        self.stopPortsButton.isEnabled = self.isBusy == false && self.listeners.isEmpty == false

        if self.listeners.isEmpty
        {
            let empty = NSTextField( labelWithString: "No listeners on Dev ports" )
            empty.font = NSFont.systemFont( ofSize: 11 )
            empty.textColor = .tertiaryLabelColor
            self.listenersStack.addArrangedSubview( empty )
            self.layoutDocument( self.listenersStack, in: self.portsScroll )
            return
        }

        for listener in self.listeners
        {
            self.listenersStack.addArrangedSubview( self.makeListenerRow( listener ) )
        }

        self.layoutDocument( self.listenersStack, in: self.portsScroll )
    }

    private func makeListenerRow( _ listener: DevPortListener ) -> NSView
    {
        let row = self.makeCardRow()
        row.edgeInsets = NSEdgeInsets( top: 5, left: 8, bottom: 5, right: 8 )

        let name = NSTextField( labelWithString: listener.processName )
        name.font = NSFont.systemFont( ofSize: 11, weight: .medium )
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( name )

        let pid = NSTextField( labelWithString: "PID \( listener.pid )" )
        pid.font = NSFont.monospacedDigitSystemFont( ofSize: 9, weight: .regular )
        pid.textColor = .tertiaryLabelColor
        pid.setContentHuggingPriority( .required, for: .horizontal )
        row.addArrangedSubview( pid )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( spacer )

        let ports = listener.ports.map( String.init ).joined( separator: ", " )
        let portsLabel = NSTextField( labelWithString: ports )
        portsLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 10, weight: .medium )
        portsLabel.textColor = .secondaryLabelColor
        portsLabel.alignment = .right
        portsLabel.setContentHuggingPriority( .required, for: .horizontal )
        row.addArrangedSubview( portsLabel )

        row.toolTip = "\( listener.processName ) (PID \( listener.pid )) — ports \( ports )"

        return row
    }

    private func layoutDocument( _ stack: NSStackView, in scroll: NSScrollView )
    {
        stack.layoutSubtreeIfNeeded()
        let width = max( scroll.contentSize.width - 12, 280 )
        let fitting = stack.fittingSize
        stack.setFrameSize( NSSize( width: width, height: max( fitting.height + 12, 1 ) ) )
        scroll.reflectScrolledClipView( scroll.contentView )
    }

    // MARK: - Actions

    @objc
    private func showMoreApps( _ sender: Any? )
    {
        guard self.apps.isEmpty == false
        else
        {
            return
        }

        let next = min( self.visibleProcessLimit + Self.visibleStep, self.apps.count )
        // Final step jumps to full scan count (virtualized — no stack hard-cap).
        if next >= self.apps.count || self.visibleProcessLimit + Self.visibleStep >= self.apps.count
        {
            self.visibleProcessLimit = self.apps.count
        }
        else
        {
            self.visibleProcessLimit = next
        }
        self.applyAppRows()
    }

    @objc
    private func quitApp( _ sender: Any? )
    {
        guard let button = sender as? NSButton,
              self.isBusy == false,
              let app = self.apps.first( where: { Int( $0.pid ) == button.tag } )
        else
        {
            return
        }

        let force = NSEvent.modifierFlags.contains( .option )
        self.isBusy = true
        self.statusLabel.stringValue = force ? "Force quitting \( app.name )…" : "Quitting \( app.name )…"

        DispatchQueue.global( qos: .userInitiated ).async
        {
            [ weak self ] in
            let result = self?.appService.quit( app, force: force ) ?? .failed

            DispatchQueue.main.async
            {
                [ weak self ] in
                guard let self = self
                else
                {
                    return
                }

                self.isBusy = false

                switch result
                {
                    case .quit:
                        self.statusLabel.stringValue = force
                            ? "Force quit \( app.name )."
                            : "Quit \( app.name )."

                    case .alreadyGone:
                        self.statusLabel.stringValue = "\( app.name ) already exited."

                    case .protected:
                        self.statusLabel.stringValue = "Protected — skipped."

                    case .stale:
                        self.statusLabel.stringValue = "Process identity changed — skipped."

                    case .failed:
                        self.statusLabel.stringValue = "Could not quit \( app.name )."
                }

                self.reloadAll( forceRefresh: true )
            }
        }
    }

    @objc
    private func stopAllListeners( _ sender: Any? )
    {
        guard self.isBusy == false
        else
        {
            return
        }

        self.isBusy = true
        self.stopPortsButton.isEnabled = false
        let count = self.listeners.count
        self.statusLabel.stringValue = count == 1
            ? "Stopping 1 Dev-port process…"
            : "Stopping \( count ) Dev-port processes…"

        DispatchQueue.global( qos: .userInitiated ).async
        {
            [ weak self ] in
            let result = self?.portService.stopListeners() ?? .nothingToStop

            DispatchQueue.main.async
            {
                [ weak self ] in
                guard let self = self
                else
                {
                    return
                }

                self.isBusy = false

                switch result
                {
                    case .nothingToStop:
                        self.statusLabel.stringValue = "Nothing left to stop."

                    case .stopped( let pids ):
                        self.statusLabel.stringValue =
                            "Stopped \( pids.count ) process\( pids.count == 1 ? "" : "es" ) — Dev ports freed."

                    case .partial( let stopped, let failed ):
                        self.statusLabel.stringValue =
                            "Stopped \( stopped.count ); \( failed.count ) failed."
                }

                self.reloadAll( forceRefresh: true )
            }
        }
    }
}

// MARK: - App process row (PID-keyed reuse)

/// Card row for one process; updated in place on refresh (rank + memory), not recreated.
private final class AppProcessRowView: NSStackView
{
    let rankLabel = NSTextField( labelWithString: "0" )
    let iconView = NSImageView()
    let nameLabel = NSTextField( labelWithString: "" )
    let metaLabel = NSTextField( labelWithString: "" )
    let memLabel = NSTextField( labelWithString: "" )
    private let memWrap = NSView()
    let quitButton = NSButton( title: "Quit", target: nil, action: nil )

    private var boundPID: pid_t = 0

    override init( frame frameRect: NSRect )
    {
        super.init( frame: frameRect )
        self.build()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder )
    {
        fatalError( "init(coder:) has not been implemented" )
    }

    func configureChrome( emphasized: Bool )
    {
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        if emphasized
        {
            self.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent( 0.12 ).cgColor
            self.layer?.borderWidth = 1
            self.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent( 0.22 ).cgColor
        }
        else
        {
            self.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent( 0.9 ).cgColor
            self.layer?.borderWidth = 1
            self.layer?.borderColor = NSColor.labelColor.withAlphaComponent( 0.06 ).cgColor
        }
    }

    func update( app: AppProcessInfo, rank: Int )
    {
        self.boundPID = app.pid
        let heavy = app.residentBytes >= 500_000_000
        let emphasized = rank <= 3

        self.rankLabel.stringValue = "\( rank )"
        self.rankLabel.textColor = emphasized ? .controlAccentColor : .tertiaryLabelColor
        self.configureChrome( emphasized: emphasized )

        self.nameLabel.stringValue = app.name
        let kind = app.isRegularApp ? "App" : "Process"
        self.metaLabel.stringValue = "\( kind ) · PID \( app.pid )"

        let memText = app.memoryUnknown
            ? "n/a"
            : AppProcessSupport.formatBytes( app.residentBytes )
        self.memLabel.stringValue = memText
        self.memLabel.textColor = heavy ? .controlAccentColor : .secondaryLabelColor
        self.memWrap.layer?.backgroundColor = ( heavy
            ? NSColor.controlAccentColor.withAlphaComponent( 0.14 )
            : NSColor.labelColor.withAlphaComponent( 0.07 ) ).cgColor

        self.quitButton.tag = Int( app.pid )
        self.toolTip = "\( app.name ) — \( memText ) · PID \( app.pid )"
    }

    private func build()
    {
        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 8
        self.edgeInsets = NSEdgeInsets( top: 7, left: 8, bottom: 7, right: 8 )
        self.translatesAutoresizingMaskIntoConstraints = false
        self.configureChrome( emphasized: false )

        self.rankLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 9, weight: .bold )
        self.rankLabel.alignment = .center
        self.rankLabel.translatesAutoresizingMaskIntoConstraints = false
        self.rankLabel.widthAnchor.constraint( equalToConstant: 18 ).isActive = true
        self.addArrangedSubview( self.rankLabel )

        self.iconView.imageScaling = .scaleProportionallyUpOrDown
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.iconView.widthAnchor.constraint( equalToConstant: 24 ).isActive = true
        self.iconView.heightAnchor.constraint( equalToConstant: 24 ).isActive = true
        self.addArrangedSubview( self.iconView )

        let nameCol = NSStackView()
        nameCol.orientation = .vertical
        nameCol.alignment = .leading
        nameCol.spacing = 1

        self.nameLabel.font = NSFont.systemFont( ofSize: 11, weight: .semibold )
        self.nameLabel.lineBreakMode = .byTruncatingTail
        self.nameLabel.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        nameCol.addArrangedSubview( self.nameLabel )

        self.metaLabel.font = NSFont.systemFont( ofSize: 9, weight: .regular )
        self.metaLabel.textColor = .tertiaryLabelColor
        nameCol.addArrangedSubview( self.metaLabel )

        self.addArrangedSubview( nameCol )
        nameCol.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        self.addArrangedSubview( spacer )

        self.memLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 10, weight: .semibold )
        self.memLabel.alignment = .center
        self.memLabel.drawsBackground = false
        self.memLabel.translatesAutoresizingMaskIntoConstraints = false

        self.memWrap.wantsLayer = true
        self.memWrap.layer?.cornerRadius = 6
        self.memWrap.translatesAutoresizingMaskIntoConstraints = false
        self.memWrap.addSubview( self.memLabel )
        NSLayoutConstraint.activate(
            [
                self.memLabel.leadingAnchor.constraint( equalTo: self.memWrap.leadingAnchor, constant: 6 ),
                self.memLabel.trailingAnchor.constraint( equalTo: self.memWrap.trailingAnchor, constant: -6 ),
                self.memLabel.topAnchor.constraint( equalTo: self.memWrap.topAnchor, constant: 2 ),
                self.memLabel.bottomAnchor.constraint( equalTo: self.memWrap.bottomAnchor, constant: -2 ),
                self.memWrap.widthAnchor.constraint( greaterThanOrEqualToConstant: 52 ),
            ]
        )
        self.memWrap.setContentHuggingPriority( .required, for: .horizontal )
        self.addArrangedSubview( self.memWrap )

        self.quitButton.bezelStyle = .recessed
        self.quitButton.controlSize = .small
        self.quitButton.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.quitButton.setContentHuggingPriority( .required, for: .horizontal )
        self.addArrangedSubview( self.quitButton )
    }
}
