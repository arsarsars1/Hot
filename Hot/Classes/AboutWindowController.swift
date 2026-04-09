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
import Darwin

public class AboutWindowController: NSWindowController
{
    @objc private dynamic var name:      String?
    @objc private dynamic var version:   String?
    @objc private dynamic var copyright: String?

    public override var windowNibName: NSNib.Name?
    {
        return "AboutWindowController"
    }

    public override func windowDidLoad()
    {
        super.windowDidLoad()

        let version = Bundle.main.object( forInfoDictionaryKey: "CFBundleShortVersionString" ) as? String ?? "0.0.0"

        if let build = Bundle.main.object( forInfoDictionaryKey: "CFBundleVersion" ) as? String
        {
            self.version = "\( version ) (\( build ))"
        }
        else
        {
            self.version = version
        }

        self.name      = Bundle.main.object( forInfoDictionaryKey: "CFBundleName"             ) as? String
        self.copyright = Bundle.main.object( forInfoDictionaryKey: "NSHumanReadableCopyright" ) as? String

        self.addAppleSiliconAboutNoteIfNeeded()
    }

    /// Uses `hw.machine` so Apple Silicon is detected even when the app runs under Rosetta.
    private static func isAppleSiliconHardware() -> Bool
    {
        var size: size_t = 0
        guard sysctlbyname( "hw.machine", nil, &size, nil, 0 ) == 0, size > 0
        else
        {
            return false
        }

        var buffer = [ CChar ]( repeating: 0, count: Int( size ) )
        guard sysctlbyname( "hw.machine", &buffer, &size, nil, 0 ) == 0
        else
        {
            return false
        }

        let machine = String( cString: buffer )
        return machine.hasPrefix( "arm64" )
    }

    private static var appleSiliconAboutBody: String
    {
        """
        Apple Silicon (M‑series): Hot shows thermal pressure, temperature, and fan speed for monitoring. macOS controls cooling automatically — this app does not change fan speeds, so you get stable readouts instead of experimental controls that may not work on your Mac or could confuse the system.
        """
    }

    private func addAppleSiliconAboutNoteIfNeeded()
    {
        guard Self.isAppleSiliconHardware(),
              let window = self.window,
              let root    = window.contentView,
              let vev     = root.subviews.first as? NSVisualEffectView,
              let icon    = vev.subviews.compactMap( { $0 as? NSImageView } ).first
        else
        {
            return
        }

        vev.layoutSubtreeIfNeeded()

        let bottomToIcon = vev.constraints.first
        {
            guard let first = $0.firstItem as? NSView, let second = $0.secondItem as? NSView else { return false }
            return first == vev && $0.firstAttribute == .bottom && second == icon && $0.secondAttribute == .bottom
        }

        bottomToIcon?.isActive = false

        let symbolImage: NSImage? =
        {
            if #available( macOS 11.0, * )
            {
                let config = NSImage.SymbolConfiguration( pointSize: 26, weight: .regular )
                return NSImage( systemSymbolName: "apple.logo", accessibilityDescription: nil )?.withSymbolConfiguration( config )
            }
            else
            {
                return NSImage( named: "CPUTemplate" )
            }
        }()

        let imageView         = NSImageView( image: symbolImage ?? NSImage( ) )
        imageView.imageScaling = .scaleProportionallyDown
        if #available( macOS 10.14, * )
        {
            imageView.contentTintColor = .secondaryLabelColor
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let text              = NSTextField( wrappingLabelWithString: Self.appleSiliconAboutBody )
        text.font             = NSFont.systemFont( ofSize: NSFont.smallSystemFontSize )
        text.textColor        = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 248
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack             = NSStackView( views: [ imageView, text ] )
        stack.orientation     = .horizontal
        stack.alignment       = .top
        stack.spacing         = 12
        stack.distribution    = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        vev.addSubview( stack )

        let constraints: [ NSLayoutConstraint ] =
        [
            imageView.widthAnchor.constraint( equalToConstant: 32 ),
            imageView.heightAnchor.constraint( equalToConstant: 32 ),
            stack.leadingAnchor.constraint( equalTo: vev.leadingAnchor, constant: 20 ),
            stack.trailingAnchor.constraint( equalTo: vev.trailingAnchor, constant: -20 ),
            stack.bottomAnchor.constraint( equalTo: vev.bottomAnchor, constant: -16 ),
            stack.topAnchor.constraint( greaterThanOrEqualTo: icon.bottomAnchor, constant: 16 ),
        ]

        NSLayoutConstraint.activate( constraints )

        window.layoutIfNeeded()
    }
}
