//
// --------------------------------------------------------------------------
// LocalizationScreenshots.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2024
// Licensed under Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

import XCTest

final class LocalizationScreenshotClass: XCTestCase {
    
    ///
    /// Constants
    ///
    
    /// Keep-in-sync with .app
    let localizedStringAnnotationActivationArgumentForScreenshottedApp = "-MF_ANNOTATE_LOCALIZED_STRINGS"
    let localizedStringAnnotationRegexForScreenshottedApp = "mfkey:(.+):(.*):" /// The first capture group is the localizationKey, the second capture group is the stringTableName
    
    /// Keep-in-sync with python script
    let xcode_screenshot_taker_output_dir_variable = "MF_LOCALIZATION_SCREENSHOT_OUTPUT_DIR"
    
    /// Keep in sync with .xcloc format
    let xcode_screenshot_taker_outputted_metadata_filename = "localizedStringData.plist"
    typealias LocalizedStringData = [LocalizedStringDatum] /// localizedStringData.plist, which is found inside .xcloc screenshot folders, has this structure
    struct LocalizedStringDatum: Encodable {
        /// Core information
        let stringKey: String
        var screenshots: [Screenshot]
        struct Screenshot: Encodable {
            let name: String
            let frame: String /// Encoding of NSRect describing where the localized ui string associated with `stringKey` appears in the screenshot.
        }
        /// These fields can be whatever I think.
        let tableName: String
        let bundlePath: String
        let bundleID: String
    }
    
    ///
    /// Internal datatypes
    ///
    
    struct ScreenshotAndMetadata {
        let screenshot: XCUIScreenshot
        let metadata: Metadata
        struct Metadata {
            let name: String
            let frames: [Frame]
            struct Frame {
                let frame: NSRect
                let strings: [String_]
                struct String_ {
                    let string: String
                    let keys: [KeyAndTable]
                    struct KeyAndTable {
                        let key: String
                        let table: String
                    }
                }
            }
        }
    }
    
    ///
    /// Main routine
    ///
    
    var app: XCUIApplication? = nil
    
    func testTakeLocalizationScreenshots() throws {
        
        /// Configure test
        self.continueAfterFailure = false
        
        /// Get output folder
        var outputDirectory: URL? = nil
        XCTContext.runActivity(named: "Get Output Folder") { activity in
            let outputDirectoryPath = ProcessInfo.processInfo.environment[xcode_screenshot_taker_output_dir_variable]
            if outputDirectoryPath != nil {
                outputDirectory = URL(fileURLWithPath: outputDirectoryPath!).absoluteURL
            }
            if outputDirectoryPath == nil {
                let currentWorkingDirectory = FileManager().temporaryDirectory
                outputDirectory = currentWorkingDirectory.appending(component: "MFLocalizationScreenshotsFallbackOutputFolder")
                DDLogInfo("No output directory provided. Using \(outputDirectory!) as a fallback.")
            }
        }
        guard let outputDirectory = outputDirectory else { fatalError() }
        
        /// Log
        DDLogInfo("Localization Screenshot Test Runner launched with output directory: \(xcode_screenshot_taker_output_dir_variable): \(outputDirectory)")
        
        /// Prepare app
        app = XCUIApplication()
        app?.launchArguments.append(localizedStringAnnotationActivationArgumentForScreenshottedApp)
        
        /// TESTING
//        app?.launchArguments.append(contentsOf: ["-AppleLanguages", "(de)"])
        
        /// Launch the app
        app!.launch()
        
        /// Call core
        var screenshotsAndMetaData: [ScreenshotAndMetadata?]? = nil
        XCTContext.runActivity(named: "Take Screenshots") { activity in
            screenshotsAndMetaData = navigateAppAndTakeScreenshots(outputDirectory)
        }
        
        /// Write results
        XCTContext.runActivity(named: "Write results") { activity in
            writeResults(screenshotsAndMetaData!, outputDirectory)
        }
    }
    
    fileprivate func navigateAppAndTakeScreenshots( _ outputDirectory: URL) -> [ScreenshotAndMetadata?] {

        /// Declare result
        var result = [ScreenshotAndMetadata?]()
        
        /// Find screen
        let screen = NSScreen.main!
        
        /// Find main window
        let window = app!.windows.firstMatch
        
        /// Find tab buttons
        let toolbarButtons = window.toolbars.firstMatch.children(matching: .button) /// `window.toolbarButtons` doesn't work for some reason.
        
        /// Find menuBar
        let menuBar = app!.menuBars.firstMatch
        
        /// TEST
        var tree = try! TreeNode<AnyObject>.tree(withKVCObject: menuBar.snapshot(), childrenKey: "children") as! TreeNode<XCUIElementSnapshot>
        
        /// Position the window
        let targetWindowY = 0.2 /// Normalized between 0 and 1
        let targetWindowPosition = NSMakePoint(screen.frame.midX - window.frame.width/2.0, /// Just center the window horizontally
                                               targetWindowY * (screen.frame.height - window.frame.height))
        let appleScript = NSAppleScript(source: """
        tell application "System Events"
            set position of window 1 of process "Mac Mouse Fix" to {\(targetWindowPosition.x), \(targetWindowPosition.y)}
        end tell
        """)
        var error: NSDictionary? = nil
        appleScript?.executeAndReturnError(&error)
        assert(error == nil)
        
        /// Screenshot menuBar itself
        result.append(takeLocalizationScreenshot(of: menuBar, name: "MenuBar"))
        
        /// Screenshot each menuBarItem
        var didClickMenuBar = false
        for (i, menuBarItem) in menuBar.menuBarItems.allElementsBoundByIndex.enumerated() {
            
            /// Skip Apple menu
            if i == 0 { continue }
            
            /// Reveal menu
            if !didClickMenuBar {
                menuBarItem.click()
                didClickMenuBar = true
            } else {
                menuBarItem.hover()
            }
            let menu = menuBarItem.menus.firstMatch
            
            /// Take screenshot of menu
            result.append(takeLocalizationScreenshot(of: menu, name: "MenuBar Menu \(i)"))
            
            /// Take screenshot with option held (reveal secret/alternative menuItems)
            XCUIElement.perform(withKeyModifiers: .option) {
                result.append(takeLocalizationScreenshot(of: menu, name: "MenuBar Menu \(i) (Option)"))
            }
        }
        
        /// Dismiss menu
        if didClickMenuBar {
            hitEscape()
        }
        
        ///
        /// Screenshot special views only accessible through the menuBar
        ///
        
        /// Find "activate" license menu item
        let macMouseFixMenuItem = menuBar.menuBarItems.allElementsBoundByIndex[1]
        macMouseFixMenuItem.click()
        let macMouseFixMenu = macMouseFixMenuItem.menus.firstMatch
        let activateLicenseItem = macMouseFixMenu.menuItems["axMenuItemActivateLicense"].firstMatch
        
        /// Click
        activateLicenseItem.click()
        
        /// Delete license key
        /// Delete license key from the textfield, so it's hidden in the screenshot, and the placeholder appears instead
        app?.typeKey(.delete, modifierFlags: [])
        
        /// Find sheet
        var sheet = window.sheets.firstMatch
        
        /// Sheenshot
        result.append(takeLocalizationScreenshot(of: sheet, name: "ActivateLicenseSheet"))
        
        /// Cleanup
        hitEscape()
        
        ///
        /// Screenshot GeneralTab
        ///
        
        /// Switch to general tab
        toolbarButtons["general"].click() /// Need to click twice so that the test runner properly waits for the animation to finish
        coolWait()
        
        /// Find enable toggle
        let switcherino = window.switches["axEnableToggle"].firstMatch
        
        /// Enable MMF (if necessary)
        let isEnabledPredicate = NSPredicate.init(format: "value == 1")
        if (isEnabledPredicate.evaluate(with: switcherino) == false) {
            switcherino.click()
            let switchIsEnabled = expectation(for: isEnabledPredicate, evaluatedWith: switcherino)
            XCTWaiter().wait(for: [switchIsEnabled], timeout: 10.0)
            coolWait() /// Wait for animation to finish
        }
        
        /// Find checkForUpdates toggle
        let updatesToggle = window.checkBoxes["axCheckForUpdatesToggle"].firstMatch
        
        /// Enable updates
        ///     (So that the beta section is expanded)
        if (updatesToggle.value as! Int) != 1 {
            updatesToggle.click()
            coolWait()
        }
        
        /// Take screenshot of fully expanded general tab
        result.append(takeLocalizationScreenshot(of: window, name: "GeneralTab"))

        ///
        /// Screenshot ButtonsTab
        ///
        
        toolbarButtons["buttons"].click()
        coolWait()
        result.append(takeLocalizationScreenshot(of: window, name: "ButtonsTab"))
        
        /// Screenshot menus
        ///     (Which let you pick the action in the remaps table)
        for (i, popupButton) in window.popUpButtons.allElementsBoundByIndex.enumerated() {
            
            /// Click
            popupButton.click()
            let menu = popupButton.menus.firstMatch
            
            /// Screenshot
            result.append(takeLocalizationScreenshot(of: menu, name: "ButtonsTab Menu \(i)"))
            
            /// Option screenshot
            XCUIElement.perform(withKeyModifiers: .option) {
                result.append(takeLocalizationScreenshot(of: menu, name: "ButtonsTab Menu \(i) (Option)"))
            }
            
            /// Clean up
            hitEscape()
        }
        
        /// Screenshot sheets
        ///     (The ones invoked by the two buttons in the bottom left and bottom right)
        for (i, button) in window.buttons.matching(NSPredicate(format: "identifier IN %@", ["axButtonsOptionsButton", "axButtonsRestoreDefaultsButton"])).allElementsBoundByIndex.enumerated() {
            
            /// Click
            button.click()
            coolWait() /// Not necessary. Sheets have a native animation where XCUITest automatically correctly
            
            /// Get sheet
            let sheet = window.sheets.firstMatch
            
            /// Screenshot
            result.append(takeLocalizationScreenshot(of: sheet, name: "ButtonsTab Sheet \(i)"))
            
            /// Cleanup
            hitEscape()
        }
        
        ///
        /// Screenshot AboutTab
        ///
        
        toolbarButtons["about"].click()
        coolWait()
        result.append(takeLocalizationScreenshot(of: window, name: "AboutTab"))
        
        /// Screenshot alert
        
        /// Click
        window.staticTexts["axAboutSendEmailButton"].firstMatch.click()
        
        /// Get sheet
        sheet = window.sheets.firstMatch
        
        /// Screenshot
        result.append(takeLocalizationScreenshot(of: sheet, name: "AboutTab Email Alert"))
        
        /// Cleanup
        hitEscape()
        
        ///
        /// Screenshot ScrollingTab
        ///
        
        toolbarButtons["scrolling"].click()
        coolWait()
        result.append(takeLocalizationScreenshot(of: window, name: "ScrollingTab"))
        
        /// Screenshot states
        for (i, popUpButton) in window.popUpButtons.allElementsBoundByIndex.enumerated() {
            
            /// Gather menu items
            popUpButton.click()
            let menuItems = popUpButton.menuItems.allElementsBoundByIndex.enumerated()
            hitEscape()
            
            for (j, menuItem) in menuItems {
                
                /// Click popUpButton
                popUpButton.click()
                if (!menuItem.isHittable || !menuItem.isEnabled) {
                    hitEscape()
                    continue
                }
                
                /// Click menu item
                menuItem.click()
                coolWait()
                
                /// Screenshot state of scrolling tab
                result.append(takeLocalizationScreenshot(of: window, name: "ScrollingTab State \(i)-\(j)"))
            }
        }
        
        /// Screenshot menus
        for (i, popUpButton) in window.popUpButtons.allElementsBoundByIndex.enumerated() {
            
            /// Click popup button
            popUpButton.click()
            let menu = popUpButton.menus.firstMatch
            
            /// Take screenshot
            result.append(takeLocalizationScreenshot(of: menu, name: "ScrollingTab Menu \(i)"))
            XCUIElement.perform(withKeyModifiers: .option) {
                if ((false)) { /// The menus on the scrolling tab don't have secret options, at least at the time of writing. NOTE: Update this if you add secret options.
                    result.append(takeLocalizationScreenshot(of: menu, name: "ScrollingTab Menu \(i) (Option)"))
                }
            }
            
            /// Cleanup
            hitEscape()
        }
        
        ///
        /// Return
        ///
        
        return result
    }
    
    ///
    /// To-file-writing
    ///
    
    fileprivate func writeResults(_ screenshotsAndMetadata: [ScreenshotAndMetadata?], _ outputDirectory: URL) {
        
        /// Convert screenshotsAndMetadata to localizedStringData.plist structure
        var screenshotNameToScreenshotDataMap = [String: Data]()
        var localizedStringData: LocalizedStringData = []
        for scr in screenshotsAndMetadata {
            
            guard let scr = scr else { continue }
            
            var screenshotUsageCount = 0
            
            let screenshot = scr.screenshot
            let screenshotName = scr.metadata.name
            for fr in scr.metadata.frames {
                let stringFrame = fr.frame
                for str in fr.strings {
                    let localizedString = str.string
                    for k in str.keys {
                        let stringKey = k.key
                        var stringTable = k.table
                        
                        /// Map empty table to "Localizable"
                        ///     Otherwise the Xcode screenshot viewer breaks.
                        if stringTable == "" { stringTable = "Localizable" }
                        
                        /// Duplicate screenshot
                        ///     Each stringKey needs its own, unique screenshot file, otherwise the Xcode viewer breaks and shows the same frame for every string key. (Tested under Xcode 15 stable & Xcode 16 Beta)
                        screenshotUsageCount += 1
                        let screenshotName = "\(screenshotUsageCount). Copy - \(screenshotName).jpeg"
                        
                        /// Convert image
                        ///     In the WWDC demos they used jpeg, but .png is a bit higher res I think.
                        guard let bitmap = screenshot.image.representations.first as? NSBitmapImageRep else { fatalError() }
                        let imageData = bitmap.representation(using: .jpeg, properties: [:])
                        
                        /// Store name -> screenshot mapping
                        screenshotNameToScreenshotDataMap[screenshotName] = imageData
                        
                        /// Store the encodable data (everything except the screenshot itself) to the localizedStringData datastructure
                        var didAttachToExistingDatum = false
                        let newScreenshotData = LocalizedStringDatum.Screenshot(name: screenshotName, frame: NSStringFromRect(stringFrame))
                        for (i, var existingDatum) in localizedStringData.enumerated() {
                            if existingDatum.stringKey == stringKey && existingDatum.tableName == stringTable {
                                existingDatum.screenshots.append(newScreenshotData)
                                localizedStringData[i] = existingDatum /// Need to directly assign to index due to Swift value types
                                assert(!didAttachToExistingDatum)
                                didAttachToExistingDatum = true
                            }
                        }
                        if !didAttachToExistingDatum {
                            let newDatum = LocalizedStringDatum(stringKey: stringKey, screenshots: [newScreenshotData], tableName: stringTable, bundlePath: "some/path", bundleID: "some.id")
                            localizedStringData.append(newDatum)
                        }
                    }
                }
            }
        }
        
        /// Create the output directory
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory.path()) {
            do {
                try fileManager.createDirectory(atPath: outputDirectory.path(), withIntermediateDirectories: true, attributes: nil)
                DDLogInfo("Output directory created: \(outputDirectory)")
            } catch {
                DDLogInfo("Error creating output directory: \((error as NSError).code) : \((error as NSError).domain)") /// This is a weird attempt at getting a non-localized description of the string
                return
            }
        }
        
        /// Write metadata to file
        do {
            let plistFileName = xcode_screenshot_taker_outputted_metadata_filename
            let plistFilePath = (outputDirectory.path() as NSString).appendingPathComponent(plistFileName)
            let plistData = try PropertyListEncoder().encode(localizedStringData)
            try plistData.write(to: URL(fileURLWithPath: plistFilePath))
        } catch {
            DDLogInfo("Error: Failed to write screenshot metadata to file as json: \(error) \((error as NSError).code) : \((error as NSError).domain)")
        }
        
        /// Write screenshots to file
        for (screenshotName, screenshotData) in screenshotNameToScreenshotDataMap {
            let filePath = (outputDirectory.path() as NSString).appendingPathComponent(screenshotName)
            do {
                try screenshotData.write(to: URL(fileURLWithPath: filePath))
            } catch {
                DDLogInfo("Error: Failed to screenshot to file: \((error as NSError).code) : \((error as NSError).domain)")
            }
        }
        
        /// Log
        DDLogInfo("Wrote result to output directory \(outputDirectory.path())")
    }
    
    ///
    /// Screenshot-taking
    ///  
    
    func takeLocalizationScreenshot(of element: XCUIElement, name screenshotBaseName: String) -> ScreenshotAndMetadata? {
        var result: ScreenshotAndMetadata? = nil
        do {
            result = try _takeLocalizationScreenshot(of: element, name: screenshotBaseName)
        } catch {
            DDLogInfo("Taking Localization screenshot threw error: \(error)")
        }
        return result
    }
    
    func _takeLocalizationScreenshot(of topLevelElement: XCUIElement, name screenshotBaseName: String) throws -> ScreenshotAndMetadata? {
            
        /// Windows and the menuBar are examples of topLevelElements
        ///     If we screenshot them separately we can screenshot all the UI our app is displaying without screenshotting the whole screen.
        
        /// Take screenshot
        let screenshot = topLevelElement.screenshot()
        
        /// Get screenshot frame
        var screenshotFrame = topLevelElement.screenshotFrame()
        
        /// Validate screenshot frame
        let displayBounds: CGRect = CGDisplayBounds(topLevelElement.screen().displayID()); /// Not sure if we should be flipping the coords
        let screenshotFrameOnScreenArea = screenshotFrame.intersection(displayBounds)
        if !screenshotFrame.equalTo(screenshotFrameOnScreenArea)  {
            if ((false)) { /// This check makes sense for menus inside the window, but for the menuBar menus this invevitably fails.
                XCTFail("Error: Screenshot would be cut off by the edge of the screen. Move the window to the center of the screen to prevent this.")
            } else {
                screenshotFrame = screenshotFrameOnScreenArea
            }
        }
        
        /// Get snapshot of ax hierarchy of topLevelElement
        let snapshot: XCUIElementSnapshot?
        do {
            snapshot = try topLevelElement.snapshot()
        } catch {
            snapshot = nil
        }
        
        /// Convert ax hierarchy to tree
        let tree = TreeNode<XCUIElementSnapshot>.tree(withKVCObject: snapshot!, childrenKey: "children")
        
        /// TEST
//        let treeDescription = tree.description()
//        DDLogInfo("The tree: \(treeDescription)")
        
        /// Find localizedStings
        ///     & their metadata
        var framesAndStringsAndKeys: [ScreenshotAndMetadata.Metadata.Frame] = []
        for nodeAsAny in tree.depthFirstEnumerator() {
            
            /// Unpack node
            let node = nodeAsAny as! TreeNode<XCUIElementSnapshot>
            let nodeSnapshot = node.representedObject!
            
            /// Get secret messages
            var localizedStrings = [ScreenshotAndMetadata.Metadata.Frame.String_]()
            for value in nodeSnapshot.dictionaryRepresentation.values {
                
                /// Check: Is it a string?
                guard let string = value as? String else {
                    continue
                }
                /// Extract any secret messages
                let secretMessages = string.secretMessages() as! [NSString]
                
                /// Extract localization key+table from each secret message
                var localizationKeys = [ScreenshotAndMetadata.Metadata.Frame.String_.KeyAndTable]()
                for secretMessage in secretMessages {
                    let secretMessage = secretMessage as String
                    let regex = try NSRegularExpression(pattern: localizedStringAnnotationRegexForScreenshottedApp, options: [])
                    let matches = regex.matches(in: secretMessage, options: [.anchored], range: .init(location: 0, length: secretMessage.utf16.count)) /// NSString and related objc classes are based on UTF16 so we should do .utf16 afaik
                    assert(matches.count <= 1)
                    var newLocalizationKey: ScreenshotAndMetadata.Metadata.Frame.String_.KeyAndTable? = nil
                    if let match = matches.first {
                        assert(match.numberOfRanges == 3) /// Full match + 2 capture groups
                        if let keyRange = Range(match.range(at: 1), in: secretMessage),
                           let tableRange = Range(match.range(at: 2), in: secretMessage) {
                            
                            newLocalizationKey = .init(key: String(secretMessage[keyRange]), table: String(secretMessage[tableRange]))
                        }
                    }
                    if let n = newLocalizationKey {
                        localizationKeys.append(n)
                    }
                }
                
                /// Append to result
                if localizationKeys.count > 0 {
                    localizedStrings.append(ScreenshotAndMetadata.Metadata.Frame.String_(string: string, keys: localizationKeys))
                }
            }
            
            /// Guard: No localizedStrings for this node
            guard !localizedStrings.isEmpty else {
                continue
            }
            
            /// Get frame for this node
            var frame = nodeSnapshot.frame
            guard frame != .zero else {
                assert(false)
                continue
            }
            
            /// Convert from screen coordinate system to screenshot's coordinate system
            ///     This is a few pixels off from what I measured with PixelSnap 2 and the values in Interface Builder, but that should be ok.
            frame = NSRect(x: frame.minX - screenshotFrame.minX,
                           y: frame.minY - screenshotFrame.minY,
                           width: frame.width,
                           height: frame.height)
            
            /// Scale to screenshot resulution
            ///     The screenshot will usually have double resolution compared the internal coordinate system. Retina stuff I think.
            let bsf = NSScreen.screens[0].backingScaleFactor /// Not sure it matters which screen we use.
            frame = NSRect(x: bsf*frame.minX,
                           y: bsf*frame.minY,
                           width: bsf*frame.width,
                           height: bsf*frame.height)
            
            /// Append to result
            framesAndStringsAndKeys.append(ScreenshotAndMetadata.Metadata.Frame(frame: frame, strings: localizedStrings))
        }
        
        /// Filter out invalid frames
        ///     Sometimes elements will show up in the hierarchy that have frame size zero. (Update: Do they?)
        let isValidFrame = { (frame: NSRect) in frame.width != 0 && frame.height != 0 }
        let groupedFrames = Dictionary(grouping: framesAndStringsAndKeys) { frameAndStringAndKey in
            isValidFrame(frameAndStringAndKey.frame)
        }
        let validFramesAndStringsAndKeys = groupedFrames[true]
        
        /// Validate
        let invalidFramesAndStringsAndKeys = groupedFrames[false]
        if (invalidFramesAndStringsAndKeys != nil) {
            assert(topLevelElement.elementType == XCUIElement.ElementType.menuBar)
        }
        
        /// Store result
        if let f = validFramesAndStringsAndKeys {
            let thisResult = ScreenshotAndMetadata(screenshot: screenshot,
                                                   metadata: ScreenshotAndMetadata.Metadata(name: screenshotBaseName,
                                                                                            frames: f))
            return thisResult
        } else {
            return nil
        }
    }
    
    ///
    /// Helper
    ///
    
    func hitEscape() {
        app?.typeKey(.escape, modifierFlags: [])
    }
    func coolWait() {
        usleep(useconds_t(Double(USEC_PER_SEC) * 0.5))
        app?._waitForQuiescence()
    }
}