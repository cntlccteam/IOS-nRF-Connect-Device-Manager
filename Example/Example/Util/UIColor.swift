/*
 * Copyright (c) 2018 Nordic Semiconductor ASA.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import UIKit

extension UIColor {
    
    static let accent: UIColor = #colorLiteral(red: 1, green: 0.4, blue: 0, alpha: 1)
    
    static let nordic: UIColor = #colorLiteral(red: 1, green: 0.4, blue: 0, alpha: 1)
    
    static let zephyr: UIColor = #colorLiteral(red: 0.3450980392, green: 0.3450980392, blue: 0.3529411765, alpha: 1)
    
    static var primary: UIColor {
        if #available(iOS 13.0, *) {
            return .label
        } else {
            return .black
        }
    }
    
    static func dynamicColor(light: UIColor, dark: UIColor) -> UIColor {
        if #available(iOS 13.0, *) {
            return UIColor { (traitCollection) -> UIColor in
                return traitCollection.userInterfaceStyle == .light ? light : dark
            }
        } else {
            return light
        }
    }
    
}
