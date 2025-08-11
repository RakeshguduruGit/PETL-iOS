//
//  PETLLiveActivityExtensionBundle.swift
//  PETLLiveActivityExtension
//
//  Created by rakesh guduru on 7/27/25.
//

import WidgetKit
import SwiftUI

@main
struct PETLLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        PETLLiveActivityExtension()
        PETLLiveActivityExtensionControl()
        PETLLiveActivityExtensionLiveActivity()
    }
}
