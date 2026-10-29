/*
 menu bar app
 click the icon and it lists the open windows. pick ur game and frame gen starts on it. pick it again to stop
 while its running the menu bar shows real fps -> shown fps and it updates evry second
 needs screen recording permision. macos asks the first time and then u gotta restart the app
 startRequestNumber is there so clicking stuff fast doesnt leave a old session running in the background
*/

import AppKit
import Metal
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct WindowChoice {
        let windowID: CGWindowID
        let menuTitle: String
    }

    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let statusLineItem = NSMenuItem(title: "Not running", action: nil, keyEquivalent: "")

    private var runningSession: FrameGenSession?
    private var runningGameWindowID: CGWindowID?
    private var runningGameName = ""
    private var lastFpsText = ""
    private var lastStopReason: String?
    private var fpsTimer: Timer?
    private var startRequestNumber = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "FrameTwin")
        statusItem.button?.imagePosition = .imageLeading
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        self.statusItem = statusItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        runningSession?.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        refreshStatusLine()
        menu.addItem(statusLineItem)
        if runningSession != nil {
            menu.addItem(makeMenuItem("Stop", action: #selector(stopClicked)))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Game window"))
        let windowChoices = findWindowChoices()
        if windowChoices.isEmpty {
            menu.addItem(NSMenuItem(title: "No windows found", action: nil, keyEquivalent: ""))
        }
        for choice in windowChoices {
            let windowItem = makeMenuItem(choice.menuTitle, action: #selector(gameWindowPicked(_:)))
            windowItem.tag = Int(choice.windowID)
            windowItem.state = choice.windowID == runningGameWindowID ? .on : .off
            menu.addItem(windowItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FrameTwin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func gameWindowPicked(_ menuItem: NSMenuItem) {
        let pickedWindowID = CGWindowID(menuItem.tag)
        let pickedTheRunningOne = pickedWindowID == runningGameWindowID
        stopRunningSession()
        lastStopReason = nil
        if pickedTheRunningOne { return }

        let pickedName = menuItem.title
        Task { await startFrameGen(gameWindowID: pickedWindowID, gameName: pickedName) }
    }

    @objc private func stopClicked() {
        stopRunningSession()
        lastStopReason = nil
    }

    @objc private func fpsTimerFired() {
        guard let runningSession else { return }
        let frameCounts = runningSession.takeFrameCounts()
        lastFpsText = "\(frameCounts.realFrames) → \(frameCounts.shownFrames) fps"
        statusItem?.button?.title = "\(frameCounts.realFrames)→\(frameCounts.shownFrames)"
        refreshStatusLine()
    }

    private func startFrameGen(gameWindowID: CGWindowID, gameName: String) async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showProblem("FrameTwin needs Screen Recording permission to see the game. Allow it in System Settings → Privacy & Security → Screen Recording, then restart FrameTwin.")
            return
        }
        guard let metalDevice else {
            showProblem("No Metal GPU found.")
            return
        }

        startRequestNumber += 1
        let thisRequestNumber = startRequestNumber
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard thisRequestNumber == startRequestNumber else { return }
            guard let gameWindow = shareableContent.windows.first(where: { $0.windowID == gameWindowID }) else {
                showProblem("Couldn't find that window anymore. Did the game close?")
                return
            }

            let session = try FrameGenSession(gameWindow: gameWindow, device: metalDevice)
            session.onStoppedByItself = { [weak self] reason in
                self?.sessionStoppedByItself(because: reason)
            }
            runningSession = session
            runningGameWindowID = gameWindowID
            runningGameName = gameName
            lastFpsText = ""
            startFpsTimer()
            session.start()
        } catch {
            showProblem("Couldn't start frame gen: \(error.localizedDescription)")
        }
    }

    private func sessionStoppedByItself(because reason: String) {
        stopRunningSession()
        lastStopReason = reason
    }

    private func stopRunningSession() {
        startRequestNumber += 1
        runningSession?.stop()
        runningSession = nil
        runningGameWindowID = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        statusItem?.button?.title = ""
    }

    private func startFpsTimer() {
        fpsTimer?.invalidate()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(fpsTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        fpsTimer = timer
    }

    private func refreshStatusLine() {
        if runningSession != nil {
            statusLineItem.title = "\(runningGameName) – \(lastFpsText.isEmpty ? "starting…" : lastFpsText)"
        } else if let lastStopReason {
            statusLineItem.title = "Stopped – \(lastStopReason)"
        } else {
            statusLineItem.title = "Not running"
        }
    }

    private func findWindowChoices() -> [WindowChoice] {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                              kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ourProcessID = ProcessInfo.processInfo.processIdentifier

        return windowInfoList.compactMap { windowInfo in
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int, windowLayer == 0,
                  let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerProcessID != ourProcessID,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  windowBounds.width >= 320, windowBounds.height >= 200 else { return nil }

            let appName = windowInfo[kCGWindowOwnerName as String] as? String ?? "Unknown app"
            let windowTitle = windowInfo[kCGWindowName as String] as? String ?? ""
            let menuTitle = windowTitle.isEmpty ? appName : "\(appName) – \(windowTitle)"
            return WindowChoice(windowID: windowID, menuTitle: menuTitle)
        }
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func showProblem(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "FrameTwin"
        alert.informativeText = message
        alert.runModal()
    }
}
