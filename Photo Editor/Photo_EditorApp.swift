//
//  Photo_EditorApp.swift
//  Photo Editor
//
//  Created by Henri Lavikainen on 6.8.2026.
//

import SwiftUI

@main
struct Photo_EditorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    #if DEBUG
                    // Development only — see DevSelfCheck.
                    if DevSelfCheck.runsAtLaunch {
                        await DevSelfCheck.run()
                    }
                    #endif
                }
        }
    }
}
