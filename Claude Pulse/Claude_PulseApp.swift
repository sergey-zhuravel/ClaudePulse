//
//  Claude_PulseApp.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import SwiftUI

@main
struct Claude_PulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
