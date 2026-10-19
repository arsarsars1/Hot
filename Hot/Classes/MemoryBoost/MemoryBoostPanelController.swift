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

/// Compact status-menu sidebar: GUI apps by memory + Dev-ports Stop All.
final class MemoryBoostPanelController: NSViewController
{
    private let appService  = AppProcessService.shared
    private let portService = DevPortStopService.shared

    private var appsStack:       NSStackView!
    private var listenersStack:  NSStackView!
    private var appsCountPill:   NSTextField!
    private var portsCountPill:  NSTextField!
    private var statusLabel:     NSTextField!
    private var stopPortsButton: NSButton!
    private var appsScroll:      NSScrollView!
    private var portsScroll:     NSScrollView!
    private var refreshTimer:    Timer?
    private var apps:            [ AppProcessInfo ] = []
    private var listeners:       [ DevPortListener ] = []
    private var isPresented      = false
    private var isBusy           = false

    override func loadView()
    {
        let root = NSView( frame: NSRect( x: 0, y: 0, width: 340, height: 420 ) )
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
        self.reloadAll()
        self.startRefreshTimer()
    }

    func prepareForSidebarHide()
    {
        self.isPresented = false
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
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
        root.addArrangedSubview( titleRow )
        titleRow.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let subtitle = NSTextField( labelWithString: "Quit heavy apps · free Dev ports" )
        subtitle.font = NSFont.systemFont( ofSize: 10, weight: .regular )
        subtitle.textColor = .tertiaryLabelColor
        root.addArrangedSubview( subtitle )

        let ( appsHeader, appsPill ) = self.makeSectionHeader( title: "Apps", detail: "by memory" )
        self.appsCountPill = appsPill
        root.addArrangedSubview( appsHeader )

        self.appsStack = NSStackView()
        self.appsStack.orientation = .vertical
        self.appsStack.alignment = .width
        self.appsStack.spacing = 5
        self.appsStack.translatesAutoresizingMaskIntoConstraints = false

        self.appsScroll = self.makeScrollHost( documentStack: self.appsStack, height: 180 )
        root.addArrangedSubview( self.appsScroll )
        self.appsScroll.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let quitHint = NSTextField( labelWithString: "⌥-click Quit to Force Quit" )
        quitHint.font = NSFont.systemFont( ofSize: 9, weight: .medium )
        quitHint.textColor = .tertiaryLabelColor
        root.addArrangedSubview( quitHint )

        root.addArrangedSubview( self.makeHairline() )

        let ( portsHeader, portsPill ) = self.makeSectionHeader(
            title: "Dev ports",
            detail: "3000–3002 · 5173–5176 · 5199"
        )
        self.portsCountPill = portsPill
        root.addArrangedSubview( portsHeader )

        self.listenersStack = NSStackView()
        self.listenersStack.orientation = .vertical
        self.listenersStack.alignment = .width
        self.listenersStack.spacing = 4
        self.listenersStack.translatesAutoresizingMaskIntoConstraints = false

        self.portsScroll = self.makeScrollHost( documentStack: self.listenersStack, height: 100 )
        root.addArrangedSubview( self.portsScroll )
        self.portsScroll.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

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
        root.addArrangedSubview( stopRow )
        stopRow.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -( inset * 2 ) ).isActive = true

        let portsHint = NSTextField(
            wrappingLabelWithString: "Stops those processes (not only the sockets) so Dev ports are free again."
        )
        portsHint.font = NSFont.systemFont( ofSize: 9 )
        portsHint.textColor = .tertiaryLabelColor
        portsHint.preferredMaxLayoutWidth = 300
        root.addArrangedSubview( portsHint )

        self.statusLabel = NSTextField( labelWithString: "Ready" )
        self.statusLabel.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        self.statusLabel.textColor = .secondaryLabelColor
        self.statusLabel.maximumNumberOfLines = 2
        self.statusLabel.preferredMaxLayoutWidth = 300
        self.statusLabel.setContentHuggingPriority( .required, for: .vertical )
        root.addArrangedSubview( self.wrapInPill( self.statusLabel ) )
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

    private func wrapInPill( _ label: NSTextField ) -> NSView
    {
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 8
        wrap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.05 ).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview( label )
        NSLayoutConstraint.activate(
            [
                label.leadingAnchor.constraint( equalTo: wrap.leadingAnchor, constant: 8 ),
                label.trailingAnchor.constraint( equalTo: wrap.trailingAnchor, constant: -8 ),
                label.topAnchor.constraint( equalTo: wrap.topAnchor, constant: 5 ),
                label.bottomAnchor.constraint( equalTo: wrap.bottomAnchor, constant: -5 ),
                wrap.widthAnchor.constraint( equalToConstant: 316 ),
            ]
        )
        return wrap
    }

    private func makeCardRow() -> NSStackView
    {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets( top: 6, left: 8, bottom: 6, right: 8 )
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent( 0.85 ).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Refresh

    private func startRefreshTimer()
    {
        self.refreshTimer?.invalidate()
        let timer = Timer( timeInterval: 2.0, repeats: true )
        {
            [ weak self ] _ in
            self?.reloadAll()
        }
        RunLoop.main.add( timer, forMode: .common )
        self.refreshTimer = timer
    }

    private func reloadAll()
    {
        guard self.isPresented, self.isBusy == false
        else
        {
            return
        }

        // NSWorkspace must be queried on the main thread — off-main often returns [].
        let apps = self.appService.listRegularApps()
        self.apps = apps
        self.rebuildAppRows()

        DispatchQueue.global( qos: .utility ).async
        {
            [ weak self ] in
            let listeners = self?.portService.discoverListeners() ?? []

            DispatchQueue.main.async
            {
                [ weak self ] in
                guard let self = self, self.isPresented
                else
                {
                    return
                }

                self.listeners = listeners
                self.rebuildListenerRows()
            }
        }
    }

    private func clearStack( _ stack: NSStackView )
    {
        stack.arrangedSubviews.forEach
        {
            stack.removeArrangedSubview( $0 )
            $0.removeFromSuperview()
        }
    }

    private func rebuildAppRows()
    {
        self.clearStack( self.appsStack )
        self.appsCountPill.stringValue = "\( self.apps.count )"

        if self.apps.isEmpty
        {
            let empty = NSTextField( labelWithString: "No other GUI apps" )
            empty.font = NSFont.systemFont( ofSize: 11 )
            empty.textColor = .tertiaryLabelColor
            self.appsStack.addArrangedSubview( empty )
            self.layoutDocument( self.appsStack, in: self.appsScroll )
            return
        }

        for ( index, app ) in self.apps.enumerated()
        {
            self.appsStack.addArrangedSubview( self.makeAppRow( app: app, tag: index ) )
        }

        self.layoutDocument( self.appsStack, in: self.appsScroll )
    }

    private func makeAppRow( app: AppProcessInfo, tag: Int ) -> NSView
    {
        let row = self.makeCardRow()

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint( equalToConstant: 22 ).isActive = true
        icon.heightAnchor.constraint( equalToConstant: 22 ).isActive = true

        if let running = NSRunningApplication( processIdentifier: app.pid )
        {
            icon.image = running.icon
        }

        row.addArrangedSubview( icon )

        let nameCol = NSStackView()
        nameCol.orientation = .vertical
        nameCol.alignment = .leading
        nameCol.spacing = 1

        let name = NSTextField( labelWithString: app.name )
        name.font = NSFont.systemFont( ofSize: 11, weight: .medium )
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        nameCol.addArrangedSubview( name )

        let memText = app.memoryUnknown
            ? "memory n/a"
            : AppProcessSupport.formatBytes( app.residentBytes )
        let mem = NSTextField( labelWithString: memText )
        mem.font = NSFont.monospacedDigitSystemFont( ofSize: 9, weight: .regular )
        mem.textColor = .tertiaryLabelColor
        nameCol.addArrangedSubview( mem )

        row.addArrangedSubview( nameCol )
        nameCol.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( spacer )

        let quit = NSButton( title: "Quit", target: self, action: #selector( self.quitApp( _: ) ) )
        quit.bezelStyle = .recessed
        quit.controlSize = .small
        quit.font = NSFont.systemFont( ofSize: 10, weight: .medium )
        quit.tag = tag
        quit.setContentHuggingPriority( .required, for: .horizontal )
        row.addArrangedSubview( quit )

        return row
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
    private func quitApp( _ sender: Any? )
    {
        guard let button = sender as? NSButton,
              button.tag >= 0,
              button.tag < self.apps.count,
              self.isBusy == false
        else
        {
            return
        }

        let app   = self.apps[ button.tag ]
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

                self.reloadAll()
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

                self.reloadAll()
            }
        }
    }
}
