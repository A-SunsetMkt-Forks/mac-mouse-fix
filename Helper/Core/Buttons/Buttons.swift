//
// --------------------------------------------------------------------------
// Buttons.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/LICENSE)
// --------------------------------------------------------------------------
//

/// TODO?: Use dispatchQueue.
///     I'm not sure the DispatchQueue is neccesary, because all the interaction with this class are naturally spaced out in time, so there's a very low chance of race conditions)

import Cocoa
import CocoaLumberjackSwift

@objc class Buttons: NSObject {
    
    /// Ivars
    static var queue: DispatchQueue = DispatchQueue(label: "com.nuebling.mac-mouse-fix.buttons", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    static private var clickCycle = ClickCycle(buttonQueue: DispatchQueue(label: "replace this"))
    static private var modifierManager = ButtonModifiers()
    
    /// Vars that we only update once per clickCycle
    static var modifiers: [AnyHashable: Any] = [:]
    static var modifications: [AnyHashable: Any] = [:]
    static var maxClickLevel: Int = -1
    
    /// Init
    private static var isInitialized = false
    private static func coolInitialize() {
        isInitialized = true
        clickCycle = ClickCycle(buttonQueue: queue)
    }
    
    /// Handling input
    
    @objc static func handleInput(device: Device, button: NSNumber, downNotUp mouseDown: Bool, event: CGEvent) -> MFEventPassThroughEvaluation {
        
        let passThroughEvaluation = kMFEventPassThroughRefusal
        
            /// Init
        if !isInitialized { coolInitialize() }
        
        /// Get remaps
        let remaps = TransformationManager.remaps()
        
        /// Update stuff when clickCycle starts
        
        let clickCycleIsActive = clickCycle.isActiveFor(device: device.uniqueID(), button: button)
        if mouseDown && !clickCycleIsActive {
            
            /// Update active device
            HelperState.updateActiveDevice(event: event)
            
            /// Update modifications
            let remaps = TransformationManager.remaps() /// This is apparently incredibly slow because Swift needs to convert the dict.
            self.modifiers = ModifierManager.getActiveModifiers(for: HelperState.activeDevice!, event: event) /// Why aren't we just using `device` here?
            self.modifications = RemapSwizzler.swizzleRemaps(remaps, activeModifiers: modifiers)
            
            /// Get max clickLevel
            self.maxClickLevel = 0
            if mouseDown {
                self.maxClickLevel = ButtonLandscapeAssessor.maxLevel(forButton: button, remaps: remaps, modificationsActingOnThisButton: modifications)
            }
            
        }
        
        /// Decide passthrough
        if self.maxClickLevel == 0 {
            return kMFEventPassThroughApproval
        }
        
        /// Dispatch through clickCycle
        clickCycle.handleClick(device: device, button: ButtonNumber(truncating: button), downNotUp: mouseDown, maxClickLevel: maxClickLevel,
                               triggerCallback: { triggerPhase, clickLevel, device, buttonNumber, onRelease in
            ///
            /// Update modifiers
            ///
            
            if triggerPhase == .press {
                self.modifierManager.update(device: device, button: ButtonNumber(truncating: button), clickLevel: clickLevel, downNotUp: true)
                onRelease.append {
                    self.modifierManager.update(device: device, button: ButtonNumber(truncating: button), clickLevel: clickLevel, downNotUp: false)
                }
            }
            
            ///
            /// Send triggers
            ///
            
            /// Debug
            DDLogDebug("triggerCallback - lvl: \(clickLevel), phase: \(triggerPhase), btn: \(buttonNumber), dev: \"\(device.name())\"")
            
            /// Asses 'mappingLandscape'
            ///     In theory we only have to do this on mouse down, because on mouse up the clickLevel doesn't change, and so no params for `assessMappingLandscape()` change
            
            var clickActionOfThisLevelExists: ObjCBool = false
            var effectForMouseDownStateOfThisLevelExists: ObjCBool = false
            var effectOfGreaterLevelExists: ObjCBool = false
            
            ButtonLandscapeAssessor.assessMappingLandscape(withButton: button as NSNumber, level: clickLevel as NSNumber, modificationsActingOnThisButton: modifications, remaps: remaps, thisClickDoBe: &clickActionOfThisLevelExists, thisDownDoBe: &effectForMouseDownStateOfThisLevelExists, greaterDoBe: &effectOfGreaterLevelExists)
            
            /// Create trigger -> action map based on mappingLandscape
            
            var map: [ClickCycleTriggerPhase: (String, MFActionPhase)] = [:]
            
            /// Map for click actions
            if clickActionOfThisLevelExists.boolValue {
                if effectOfGreaterLevelExists.boolValue {
                    map[.levelExpired]          = ("click", kMFActionPhaseCombined)
                } else if effectForMouseDownStateOfThisLevelExists.boolValue {
                    map[.release]               = ("click", kMFActionPhaseCombined)
//                    map[.releaseFromHold]       = ("click", kMFActionPhaseCombined)
                } else {
                    map[.press]                 = ("click", kMFActionPhaseStart)
                }
            }
            
            /// Map for hold actions
            if effectForMouseDownStateOfThisLevelExists.boolValue {
                map[.hold]                  = ("hold", kMFActionPhaseStart)
            }
            
            /// Get action for current trigger
            ///     This code is horrible to write in Swift. Deal with remapsDict in Objc whenever possible
            
            /// Get actionArray
            guard
                let (duration, startOrEnd) = map[triggerPhase],
                let m1 = modifications[button] as? [AnyHashable: Any],
                let m2 = m1[clickLevel as NSNumber] as? [AnyHashable: Any],
                let m3 = m2[duration],
                let actionArray = m3 as? [[AnyHashable: Any]] /// Not nil -> a click/hold action does exist for this button + level + duration
            else {
                return /// Return if there's no action array to send
            }
            
            /// Add modifiers to actionArray for addMode. See TransformationManager -> AddMode for context
            ///     Edit: We don't need this anymore now that we're using the addModeSwizzler
//            if actionArray[0][kMFActionDictKeyType] as! String == kMFActionDictTypeAddModeFeedback {
//                actionArray[0][kMFRemapsKeyModificationPrecondition] = self.modifiers
//            }
            
            /// Notify TrialCounter.swift
            TrialCounter.shared.handleUse()
            
            /// Execute actionArray
            if startOrEnd == kMFActionPhaseCombined {
                Actions.executeActionArray(actionArray, phase: kMFActionPhaseCombined)
            } else if startOrEnd == kMFActionPhaseStart {
                Actions.executeActionArray(actionArray, phase: kMFActionPhaseStart)
                onRelease.append {
                    DDLogDebug("triggerCallback - unconditionalRelease button \(button)")
                    Actions.executeActionArray(actionArray, phase: kMFActionPhaseEnd)
                }
            }
            
            /// Notify triggering button
            ///     For levelExpired and .releaseFromHold, we know that the clickCycle will be killed right after this callback.
            ///     In that case it might not be necessary to notify the triggering button.
            self.handleButtonHasHadDirectEffect_Unsafe(device: device, button: button)
            
            /// Notify modifiers
            ///     (Probably unnecessary, because the only modifiers that can be "deactivated" are buttons. And since there's only one clickCycle, any buttons modifying the current one should already be zombified)
            ModifierManager.handleModificationHasBeenUsed(with: device, activeModifiers: self.modifiers)
        })
        
        return passThroughEvaluation
    }
    
    
    /// Effect feedback
    
    @objc static func handleButtonHasHadDirectEffect(device: Device, button: NSNumber) {
        handleButtonHasHadDirectEffect_Unsafe(device: device, button: button)
    }
    
    @objc static func handleButtonHasHadDirectEffect_Unsafe(device: Device, button: NSNumber) {
        /// Validate
        /// Might wanna `assert(clickCycleIsActive)`
        assert(isInitialized)
        /// Do stuff
        if self.clickCycle.isActiveFor(device: device.uniqueID(), button: button) {
            self.clickCycle.kill()
        }
        self.modifierManager.kill(device: device, button: ButtonNumber(truncating: button)) /// Not sure abt this
    }
    
    @objc static func handleButtonHasHadEffectAsModifier(device: Device, button: NSNumber) {
        handleButtonHasHadEffectAsModifier_Unsafe(device: device, button: button)
    }
    
    @objc static func handleButtonHasHadEffectAsModifier_Unsafe(device: Device, button: NSNumber) {
        /// Validate
        /// Might wanna `assert(buttonIsHeld)`
        assert(isInitialized)
        /// Do stuff
        if self.clickCycle.isActiveFor(device: device.uniqueID(), button: button) {
            self.clickCycle.kill()
        }
    }
    
    /// Interface for accessing submodules
    
    @objc static func getActiveButtonModifiers_Unsafe(device: Device) -> [[String: Int]] {
        return modifierManager.getActiveButtonModifiersForDevice(device: device)
    }
    
}