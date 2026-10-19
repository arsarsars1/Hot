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

/// Compact system RAM card for the status-menu metrics column.
final class SystemMemoryMeterView: NSView
{
    private let titleLabel  = NSTextField( labelWithString: "Memory" )
    private let valueLabel  = NSTextField( labelWithString: "—" )
    private let percentLabel = NSTextField( labelWithString: "" )
    private let track       = NSView()
    private let fill        = NSView()
    private var fillWidth:  NSLayoutConstraint!

    override init( frame frameRect: NSRect )
    {
        super.init( frame: frameRect )
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.04 ).cgColor
        self.build()
    }

    required init?( coder: NSCoder )
    {
        fatalError( "init(coder:) has not been implemented" )
    }

    private func build()
    {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets( top: 10, left: 12, bottom: 10, right: 12 )
        root.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview( root )

        NSLayoutConstraint.activate(
            [
                root.leadingAnchor.constraint( equalTo: self.leadingAnchor ),
                root.trailingAnchor.constraint( equalTo: self.trailingAnchor ),
                root.topAnchor.constraint( equalTo: self.topAnchor ),
                root.bottomAnchor.constraint( equalTo: self.bottomAnchor ),
            ]
        )

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        self.titleLabel.font = NSFont.systemFont( ofSize: 11, weight: .semibold )
        self.titleLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview( self.titleLabel )

        let spacer = NSView()
        spacer.setContentHuggingPriority( .defaultLow, for: .horizontal )
        header.addArrangedSubview( spacer )

        self.percentLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 11, weight: .semibold )
        self.percentLabel.textColor = .labelColor
        header.addArrangedSubview( self.percentLabel )
        root.addArrangedSubview( header )
        header.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -24 ).isActive = true

        self.valueLabel.font = NSFont.monospacedDigitSystemFont( ofSize: 12, weight: .medium )
        self.valueLabel.textColor = .labelColor
        root.addArrangedSubview( self.valueLabel )

        self.track.wantsLayer = true
        self.track.layer?.cornerRadius = 3
        self.track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent( 0.08 ).cgColor
        self.track.translatesAutoresizingMaskIntoConstraints = false
        self.track.heightAnchor.constraint( equalToConstant: 6 ).isActive = true

        self.fill.wantsLayer = true
        self.fill.layer?.cornerRadius = 3
        if #available( macOS 10.14, * )
        {
            self.fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        else
        {
            self.fill.layer?.backgroundColor = NSColor.selectedControlColor.cgColor
        }
        self.fill.translatesAutoresizingMaskIntoConstraints = false
        self.track.addSubview( self.fill )

        self.fillWidth = self.fill.widthAnchor.constraint( equalToConstant: 0 )
        NSLayoutConstraint.activate(
            [
                self.fill.leadingAnchor.constraint( equalTo: self.track.leadingAnchor ),
                self.fill.topAnchor.constraint( equalTo: self.track.topAnchor ),
                self.fill.bottomAnchor.constraint( equalTo: self.track.bottomAnchor ),
                self.fillWidth,
            ]
        )

        root.addArrangedSubview( self.track )
        self.track.widthAnchor.constraint( equalTo: root.widthAnchor, constant: -24 ).isActive = true

        let hint = NSTextField( labelWithString: "System RAM · approximate" )
        hint.font = NSFont.systemFont( ofSize: 9 )
        hint.textColor = .tertiaryLabelColor
        root.addArrangedSubview( hint )
    }

    func apply( _ snap: SystemMemorySnapshot )
    {
        self.valueLabel.stringValue = SystemMemorySupport.summaryLine( snap )
        self.percentLabel.stringValue = "\( snap.usedPercent )%"

        self.layoutSubtreeIfNeeded()
        let width = max( self.track.bounds.width, 1 )
        self.fillWidth.constant = width * CGFloat( snap.usedFraction )

        // Warm tint when memory is high.
        if #available( macOS 10.14, * )
        {
            if snap.usedPercent >= 85
            {
                self.fill.layer?.backgroundColor = NSColor.systemOrange.cgColor
            }
            else if snap.usedPercent >= 70
            {
                self.fill.layer?.backgroundColor = NSColor.systemYellow.cgColor
            }
            else
            {
                self.fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            }
        }
    }
}
