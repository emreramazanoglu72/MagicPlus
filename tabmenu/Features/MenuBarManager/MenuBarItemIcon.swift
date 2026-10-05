//
//  MenuBarItemIcon.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// A menu bar item as it looks in the bar, falling back to the owning app's icon when the
/// bar cannot be captured — the same trade the window previews make.
struct MenuBarItemIcon: View {
    let item: MenuBarItem
    let images: MenuBarItemImageCache
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let capture = images.image(for: item) {
                Image(nsImage: capture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let icon = item.application?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(item.displayName)
    }
}
