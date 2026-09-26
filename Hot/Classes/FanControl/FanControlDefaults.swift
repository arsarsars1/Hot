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

import Foundation

enum FanControlDefaults
{
    static let mode = "fanControlMode"
    static let coolingLevel = "fanControlCoolingLevel"
    static let curves = "fanControlCurves"
    static let recoveryNeeded = "fanControlRecoveryNeeded"
    static let helperVersion = "fanControlHelperVersion"
    /// Re-apply Manual/Curve after sleep/wake. Default: true.
    static let resumeAfterSleep = "fanControlResumeAfterSleep"
    /// Re-apply saved Manual/Curve when Hot launches. Default: false (quit always returns to System).
    static let restoreOnLaunch = "fanControlRestoreOnLaunch"

    static func registerLifecycleDefaults()
    {
        UserDefaults.standard.register(
            defaults: [
                resumeAfterSleep: true,
                restoreOnLaunch: false,
            ]
        )
    }

    static var shouldResumeAfterSleep: Bool
    {
        if UserDefaults.standard.object( forKey: resumeAfterSleep ) == nil
        {
            return true
        }

        return UserDefaults.standard.bool( forKey: resumeAfterSleep )
    }

    static var shouldRestoreOnLaunch: Bool
    {
        UserDefaults.standard.bool( forKey: restoreOnLaunch )
    }
}
