//
//  Decathon_POCApp.swift
//  Decathon POC
//
//  Created by Rushikesh Suradkar  on 07/10/26.
//

import SwiftUI
import QuinKitLogger

@main
struct Decathon_POCApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bluetoothSession = BluetoothSession()

    init() {
        QKLog.configure(.init(persistLogs: true, retentionDays: 7))
        QKLog.debug(tag: "App", "QUIN PRO POC launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: bluetoothSession)
                .tint(.accentColor)
                .task {
                    await bluetoothSession.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await bluetoothSession.didBecomeActive() }
                    } else if phase == .background {
                        bluetoothSession.didEnterBackground()
                    }
                }
        }
    }
}
