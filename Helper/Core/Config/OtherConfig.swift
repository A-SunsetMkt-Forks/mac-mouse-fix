//
// --------------------------------------------------------------------------
// OtherConfig.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under MIT
// --------------------------------------------------------------------------
//

import Cocoa

@objc class OtherConfig: NSObject {

    /// Reload from config dict
    ///     Use this to delete cached values
    @objc static func reload() {
        
    }
    
    /// Advanced settings
    
    @objc static func freezePointerDuringModifiedDrag() -> Bool {
        return false
    }
    @objc static var doubleClickThreshold: Double {
        return 0.01;
    }
    
    /// Internal
    
    @objc static func mouseMovingMaxIntervalLarge() -> Double {
        return 0.1
    }
    
    @objc static func mouseMovingMaxIntervalSmall() -> Double {
        return 0.04
        /// ^ Only consider the mouse moving, if less than this time interval has passed between the last two events
        /// Notes from using this in ModifiedDrag:
        /// - 0.05 is a little too low. It will sometimes stop when you don't want it to when driving it through click and drag.
        /// - 0.07 is still a little low when the computer is laggy
        /// - I settled on 0.1
        /// Edit: I'm also using this in PointerFreeze now, and there 0.04 or lower seems appropriate (But my computer is also running fast at the moment). Won't go into why, but I think it's probably better to heir on the side of larger for MomentumScroll and smaller for PointerFreeze. -> I'll create two values: mouseMovingMaxIntervalLarge, and mouseMovingMaxIntervalSmall.
    }
    
}
