/*
 * Copyright (c) 2018 Nordic Semiconductor ASA.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import CoreBluetooth
import UIKit

class DiscoveredPeripheral: NSObject {
    //MARK: - Properties
    public private(set) var basePeripheral      : CBPeripheral
    public private(set) var advertisedName      : String
    public private(set) var RSSI                : NSNumber = -127
    public private(set) var highestRSSI         : NSNumber = -127
    public private(set) var advertisedServices  : [CBUUID]?
    public var enableEnOceanRadioBasedCommissioningButton : UIButton
    public var bd_addr : String
    public var blinkingEnOceanRadioBasedCommissioningButton : Timer
    public var enabledEnOceanRadioBasedCommissioning : Bool
    public var commissionedEnOceanDevice : Bool
    public var activatedAttentionButton : UIButton
    public var blinkingAttentionButton : Timer

    init(_ aPeripheral: CBPeripheral) {
        basePeripheral = aPeripheral
        advertisedName = ""
        bd_addr = ""
        enableEnOceanRadioBasedCommissioningButton = UIButton()
        blinkingEnOceanRadioBasedCommissioningButton = Timer()
        enabledEnOceanRadioBasedCommissioning = false
        commissionedEnOceanDevice = false
        activatedAttentionButton = UIButton()
        blinkingAttentionButton = Timer()
        super.init()
    }
    
    func update(withAdvertisementData anAdvertisementDictionary: [String : Any], andRSSI anRSSI: NSNumber) {
        (advertisedName, advertisedServices) = parseAdvertisementData(anAdvertisementDictionary)
        
        if anRSSI.decimalValue != 127 {
            RSSI = anRSSI
        
            if RSSI.decimalValue > highestRSSI.decimalValue {
                highestRSSI = RSSI
            }
        }
    }
    
    private func parseAdvertisementData(_ anAdvertisementDictionary: [String : Any]) -> (String, [CBUUID]?) {
        var advertisedName: String
        var advertisedServices: [CBUUID]?
        
        if let name = anAdvertisementDictionary[CBAdvertisementDataLocalNameKey] as? String {
            advertisedName = name
        } else {
            advertisedName = "N/A"
        }
        if let services = anAdvertisementDictionary[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            advertisedServices = services
        } else {
            advertisedServices = nil
        }
        
        return (advertisedName, advertisedServices)
    }
    
    //MARK: - NSObject protocols
    override func isEqual(_ object: Any?) -> Bool {
        if object is DiscoveredPeripheral {
            let peripheralObject = object as! DiscoveredPeripheral
            return peripheralObject.basePeripheral.identifier == basePeripheral.identifier
        } else if object is CBPeripheral {
            let peripheralObject = object as! CBPeripheral
            return peripheralObject.identifier == basePeripheral.identifier
        } else {
            return false
        }
    }
}
