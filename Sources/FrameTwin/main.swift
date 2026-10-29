/*
 entry point
 FrameTwin --selftest [folder]   checks the frame gen math with fake frames and saves pngs
 FrameTwin                       runs the menu bar app
*/

import AppKit

let launchArguments = CommandLine.arguments

if let selfTestFlagIndex = launchArguments.firstIndex(of: "--selftest") {
    let folderArgumentIndex = selfTestFlagIndex + 1
    let outputFolder = folderArgumentIndex < launchArguments.count
        ? URL(fileURLWithPath: launchArguments[folderArgumentIndex])
        : FileManager.default.temporaryDirectory.appendingPathComponent("frametwin-selftest")
    exit(SelfTest.run(outputFolder: outputFolder))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
