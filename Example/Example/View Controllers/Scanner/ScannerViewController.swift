/*
 * Copyright (c) 2018 Nordic Semiconductor ASA.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import UIKit
import CoreBluetooth
import McuManager

class ScannerViewController: UITableViewController, CBCentralManagerDelegate, UIPopoverPresentationControllerDelegate, ScannerFilterDelegate {
    
    public static let DTS_SERVICE = CBUUID(string: "09def0c1-7b06-4f33-8a82-7cb03e25e7f7")
    public static let DTS_CHARACTERISTIC_TX = CBUUID(string: "09def0c2-7b06-4f33-8a82-7cb03e25e7f7")
    public static let DTS_CHARACTERISTIC_RX = CBUUID(string: "09def0c3-7b06-4f33-8a82-7cb03e25e7f7")

    @IBOutlet weak var emptyPeripheralsView: UIView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals = [DiscoveredPeripheral]()
    private var filteredPeripherals = [DiscoveredPeripheral]()
    
    private var filterByUuid: Bool!
    private var filterByRssi: Bool!
    
    /// Lock used to wait for callbacks before continuing the request. This lock
    /// is used to wait for the device to setup (i.e. connection, descriptor
    /// writes) and the device to be received.
    private let lock = ResultLock(isOpen: false)
    
    /// Max number of retries until the transaction is failed.
    private static let MAX_RETRIES = 3
    /// Connection timeout in seconds.
    private static let CONNECTION_TIMEOUT = 20
    /// Transaction timout in seconds.
    private static let TRANSACTION_TIMEOUT = 30

    // Message types for writing to Data Transfer RX Characteristic
    private enum DtRxMessageType : Int {
        case undefined = 0
        case requestForBdAddr = 1
        case requestForBdAddrInitial = 2
        case requestForNrEnOceanDevs = 3
        case enableEnOceanRadiobasedCommissioning = 4
        case disableEnOceanRadiobasedCommissioning = 5
        case decommissionEnOceanDevice = 6
        case triggerDeviceAttention = 7
    }
    
    private var command = DtRxMessageType.undefined
    
    @IBAction func aboutTapped(_ sender: UIBarButtonItem) {
        let rootViewController = navigationController as? RootViewController
        rootViewController?.showIntro(animated: true)
    }

    @objc func blinkAttentionButton(timer: Timer) {
        guard let userInfo = timer.userInfo as? [String: DiscoveredPeripheral] else { return }
        let peripheral = userInfo["peripheral"]
        let buttonColor = peripheral?.activatedAttentionButton.tintColor
        if buttonColor == UIColor.orange {
            peripheral?.activatedAttentionButton.tintColor = UIColor.white
        } else {
            peripheral?.activatedAttentionButton.tintColor = UIColor.orange
        }
    }
    
    @objc func blinkEnOceanRadioBasedCommissioningButton(timer: Timer) {
        guard let userInfo = timer.userInfo as? [String: DiscoveredPeripheral] else { return }
        let peripheral = userInfo["peripheral"]
        let buttonColor = peripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor
        if buttonColor == UIColor.orange {
            peripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.white
        } else {
            peripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
        }
    }

    @IBAction func aboutTappedAttentionButton(_ sender: UIButton) {
        var superview = sender.superview
        while let view = superview, !(view is UITableViewCell) {
            superview = view.superview
        }
        guard let cell = superview as? UITableViewCell else {
            return
        }
        guard let indexPath = tableView.indexPath(for: cell) else {
            return
        }
        // We've got the index path for the cell that contains the button,
        // now go for sending attention message to corresponding peripheral
        let filteredPeripheral = filteredPeripherals[indexPath.row]
        let peripheral = filteredPeripheral.basePeripheral
        filteredPeripheral.activatedAttentionButton = sender
        filteredPeripheral.activatedAttentionButton.tintColor = UIColor.orange
        command = DtRxMessageType.triggerDeviceAttention
        centralManager.connect(peripheral)
    }
    
    @IBAction func aboutTappedEnableEnOceanRadioBasedCommissioningButton(_ sender: UIButton) {
        var superview = sender.superview
        while let view = superview, !(view is UITableViewCell) {
            superview = view.superview
        }
        guard let cell = superview as? UITableViewCell else {
            return
        }
        guard let indexPath = tableView.indexPath(for: cell) else {
            return
        }
        // We've got the index path for the cell that contains the button,
        // now go for sending attention message to corresponding peripheral
        
        let filteredPeripheral = filteredPeripherals[indexPath.row]
        let peripheral = filteredPeripheral.basePeripheral
        filteredPeripheral.enableEnOceanRadioBasedCommissioningButton = sender
        filteredPeripheral.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
        if filteredPeripheral.commissionedEnOceanDevice == false {
            if filteredPeripheral.enabledEnOceanRadioBasedCommissioning == false {
                command = DtRxMessageType.enableEnOceanRadiobasedCommissioning
            } else {
                command = DtRxMessageType.disableEnOceanRadiobasedCommissioning
            }
        } else {
            // Create Alert
            let dialogMessage = UIAlertController(title: "Confirm", message: "Are you sure you want to decommission this EnOcean device?", preferredStyle: .alert)
            // Create OK button with action handler
            let ok = UIAlertAction(title: "OK", style: .default, handler: { (action) -> Void in
                self.command = DtRxMessageType.decommissionEnOceanDevice
                self.centralManager.connect(peripheral)
            })
            // Create Cancel button with action handlder
            let cancel = UIAlertAction(title: "Cancel", style: .cancel) { (action) -> Void in
                filteredPeripheral.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
                return
            }
            //Add OK and Cancel button to an Alert object
            dialogMessage.addAction(ok)
            dialogMessage.addAction(cancel)
            // Present alert message to user
            self.present(dialogMessage, animated: true, completion: nil)
        }
        centralManager.connect(peripheral)
    }
    
    // MARK: - UIViewController
    override func viewDidLoad() {
        super.viewDidLoad()
        centralManager = CBCentralManager()
        centralManager.delegate = self
        
        filterByUuid = UserDefaults.standard.bool(forKey: "filterByUuid")
        filterByRssi = UserDefaults.standard.bool(forKey: "filterByRssi")
        
        discoveredPeripherals.removeAll()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if centralManager.state == .poweredOn {
            activityIndicator.startAnimating()
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if view.subviews.contains(emptyPeripheralsView) {
            coordinator.animate(alongsideTransition: { (context) in
                let width = self.emptyPeripheralsView.frame.size.width
                let height = self.emptyPeripheralsView.frame.size.height
                if context.containerView.frame.size.height > context.containerView.frame.size.width {
                    self.emptyPeripheralsView.frame = CGRect(x: 0,
                                                             y: (context.containerView.frame.size.height / 2) - (height / 2),
                                                             width: width,
                                                             height: height)
                } else {
                    self.emptyPeripheralsView.frame = CGRect(x: 0,
                                                             y: 16,
                                                             width: width,
                                                             height: height)
                }
            })
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        for filteredPeripheral in filteredPeripherals {
            centralManager.cancelPeripheralConnection(filteredPeripheral.basePeripheral)
        }
    }
    
    // MARK: - Segue control
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        let identifier = segue.identifier!
        switch identifier {
        case "showFilter":
            let filterController = segue.destination as! ScannerFilterViewController
            filterController.popoverPresentationController?.delegate = self
            filterController.filterByUuidEnabled = filterByUuid
            filterController.filterByRssiEnabled = filterByRssi
            filterController.delegate = self
        case "connect":
            let controller = segue.destination as! BaseViewController
            controller.peripheral = (sender as! DiscoveredPeripheral)
        default:
            break
        }
    }
    
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        // This will force the Filter ViewController
        // to be displayed as a popover on iPhones.
        return .none
    }
    
    // MARK: - Filter delegate
    func filterSettingsDidChange(filterByUuid: Bool, filterByRssi: Bool) {
        self.filterByUuid = filterByUuid
        self.filterByRssi = filterByRssi
        UserDefaults.standard.set(filterByUuid, forKey: "filterByUuid")
        UserDefaults.standard.set(filterByRssi, forKey: "filterByRssi")
        
        filteredPeripherals.removeAll()
        for peripheral in discoveredPeripherals {
            if matchesFilters(peripheral) {
                filteredPeripherals.append(peripheral)
            }
        }
        tableView.reloadData()
    }
    
    // MARK: - Table view data source
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if filteredPeripherals.count > 0 {
            hideEmptyPeripheralsView()
        } else {
            showEmptyPeripheralsView()
        }
        return filteredPeripherals.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let aCell = tableView.dequeueReusableCell(withIdentifier: ScannerTableViewCell.reuseIdentifier, for: indexPath) as! ScannerTableViewCell
        aCell.setupViewWithPeripheral(filteredPeripherals[indexPath.row])
        return aCell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        centralManager.stopScan()
        activityIndicator.stopAnimating()
        
        performSegue(withIdentifier: "connect", sender: filteredPeripherals[indexPath.row])
    }
    
    // MARK: - CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([ScannerViewController.DTS_SERVICE])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        // Find peripheral among already discovered ones, or create a new object if it is a new one.
        var discoveredPeripheral = discoveredPeripherals.first(where: { $0.basePeripheral.identifier == peripheral.identifier })
        if discoveredPeripheral == nil {
            discoveredPeripheral = DiscoveredPeripheral(peripheral)
            discoveredPeripherals.append(discoveredPeripheral!)
        }
        
        // Update the object with new values.
        discoveredPeripheral!.update(withAdvertisementData: advertisementData, andRSSI: RSSI)
        
        // If the device is already on the filtered list, update it.
        // It will be shown even if the advertising packet is no longer
        // matching the filter. We don't want any blinking on the device list.
        if let index = filteredPeripherals.firstIndex(of: discoveredPeripheral!) {
            // Update the cell views directly, without refreshing the whole table.
            if let aCell = tableView.cellForRow(at: [0, index]) as? ScannerTableViewCell {
                aCell.peripheralUpdatedAdvertisementData(discoveredPeripheral!)
            }
        } else {
            // Check if the peripheral matches the current filters.
            if matchesFilters(discoveredPeripheral!) {
                if command == DtRxMessageType.undefined {
                    command = DtRxMessageType.requestForBdAddrInitial
                    centralManager.connect(peripheral)
                }
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            activityIndicator.stopAnimating()
        } else {
            activityIndicator.startAnimating()
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
        }
    }

    // MARK: - Private helper methods
    
    /// Shows the No Peripherals view.
    private func showEmptyPeripheralsView() {
        if !view.subviews.contains(emptyPeripheralsView) {
            view.addSubview(emptyPeripheralsView)
            emptyPeripheralsView.alpha = 0
            emptyPeripheralsView.frame = CGRect(x: 0,
                                                y: (view.frame.height / 2) - (emptyPeripheralsView.frame.size.height / 2),
                                                width: view.frame.width,
                                                height: emptyPeripheralsView.frame.height)
            view.bringSubviewToFront(emptyPeripheralsView)
            UIView.animate(withDuration: 0.5, animations: {
                self.emptyPeripheralsView.alpha = 1
            })
        }
    }
    
    /// Hides the No Peripherals view. This method should be
    /// called when a first peripheral was found.
    private func hideEmptyPeripheralsView() {
        if view.subviews.contains(emptyPeripheralsView) {
            UIView.animate(withDuration: 0.5, animations: {
                self.emptyPeripheralsView.alpha = 0
            }, completion: { (completed) in
                self.emptyPeripheralsView.removeFromSuperview()
            })
        }
    }
    
    public let MESH_PROVS_SERVICE = CBUUID(string: "00001827-0000-1000-8000-00805f9b34fb")
    public let MESH_PROXY_SERVICE = CBUUID(string: "00001828-0000-1000-8000-00805f9b34fb")
    /// Returns true if the discovered peripheral matches
    /// current filter settings.
    ///
    /// - parameter discoveredPeripheral: A peripheral to check.
    /// - returns: True, if the peripheral matches the filter,
    ///   false otherwise.
    private func matchesFilters(_ discoveredPeripheral: DiscoveredPeripheral) -> Bool {
        if filterByUuid &&
            (discoveredPeripheral.advertisedServices?.contains(McuMgrBleTransport.SMP_SERVICE) != true) &&
            (discoveredPeripheral.advertisedServices?.contains(ScannerViewController.DTS_SERVICE) != true) &&
            (discoveredPeripheral.advertisedServices?.contains(MESH_PROVS_SERVICE) != true) &&
            (discoveredPeripheral.advertisedServices?.contains(MESH_PROXY_SERVICE) != true)
        {
            return false
        }
        if filterByRssi && discoveredPeripheral.highestRSSI.decimalValue < -50 {
            return false
        }
        return true
    }
}

extension ScannerViewController: CBPeripheralDelegate {
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            command = DtRxMessageType.undefined
            return
        }
        guard peripheral.services?.count != 0 else {
            command = DtRxMessageType.undefined
            return
        }
        let s = peripheral.services?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"
        guard let services = peripheral.services else {
            command = DtRxMessageType.undefined
            return
        }

        // only take LCC devices into the list which have SMP and DTS Service
        var discoveredSMP = false
        var discoveredDTS = false
        for service in services {
            if service.uuid == McuMgrBleTransport.SMP_SERVICE {
                discoveredSMP = true
            }
            if service.uuid == ScannerViewController.DTS_SERVICE {
                discoveredDTS = true
            }
        }
        if discoveredSMP == false && discoveredDTS == false {
            centralManager.cancelPeripheralConnection(peripheral)
            command = DtRxMessageType.undefined
            return
        }
        let discoveredPeripheral = discoveredPeripherals.first(where: { $0.basePeripheral.identifier == peripheral.identifier })
        if command == .requestForBdAddrInitial {
            filteredPeripherals.append(discoveredPeripheral!)
        }
        tableView.reloadData()
        for service in services {
            if service.uuid == ScannerViewController.DTS_SERVICE {
                peripheral.discoverCharacteristics([ScannerViewController.DTS_CHARACTERISTIC_RX, ScannerViewController.DTS_CHARACTERISTIC_TX], for: service)
                return
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard error == nil else {
            return
        }
        guard let characteristics = service.characteristics else {
            return
        }

        _ = service.characteristics?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"

        for characteristic in characteristics {
            if characteristic.uuid == ScannerViewController.DTS_CHARACTERISTIC_RX {
                var data = Data()
                switch command {
                    case .requestForBdAddr:
                        data = Data([0x01, 0x01, 0x01])
                        break
                    case .requestForBdAddrInitial:
                        // requests 2 MSB of BD_ADDR and number of comissioned EnOcean devices
                        data = Data([0x01, 0x01, 0x03])
                        break
                    case .enableEnOceanRadiobasedCommissioning:
                        data = Data([0x02, 0x01, 0x01])
                        break
                    case .decommissionEnOceanDevice:
                        data = Data([0x02, 0x01, 0x05])
                        break
                    case .disableEnOceanRadiobasedCommissioning:
                        data = Data([0x02, 0x01, 0x02])
                        break
                    case .triggerDeviceAttention:
                        data = Data([0x02, 0x01, 0x03])
                        break
                    case .undefined:
                        break
                    case .requestForNrEnOceanDevs:
                        break
                }
                if !data.isEmpty {
                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                }
            }
            else if characteristic.uuid == ScannerViewController.DTS_CHARACTERISTIC_TX {
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Check for error.
        guard error == nil else {
            return
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Check for error.
        guard error == nil else {
            return
        }
        guard let data = characteristic.value else {
            return
        }

        let arData = Array(data)

        let discoveredPeripheral = discoveredPeripherals.first(where: { $0.basePeripheral.identifier == peripheral.identifier })
        if let index = filteredPeripherals.firstIndex(of: discoveredPeripheral!) {
            command = DtRxMessageType.undefined
            // Update the cell views directly, without refreshing the whole table.
            if let aCell = tableView.cellForRow(at: [0, index]) as? ScannerTableViewCell {
                // Generic_Request_Response
                if arData[0] == 0x04 {
                    // Response contains BBD_ADDR
                    if arData[2] == 0x01 {
                        if arData[1] < 7 {
                            return
                        }
                        discoveredPeripheral?.bd_addr = String(format: " %02x%02x", arData[3], arData[4])
                        aCell.peripheralUpdatedAdvertisementData(discoveredPeripheral!)
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                    // Response contains B2 MSB of BD_ADDR and number of commissioned EnOcean devices
                    else if arData[2] == 0x03 {
                        if arData[1] < 4 {
                            return
                        }
                        discoveredPeripheral?.bd_addr = String(format: " %02x%02x", arData[3], arData[4])
                        let nrOfEnOceanDevs = arData[5]
                        if nrOfEnOceanDevs > 0 {
                            discoveredPeripheral?.commissionedEnOceanDevice = true
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
                        } else {
                            discoveredPeripheral?.commissionedEnOceanDevice = false
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.black
                        }
                        aCell.peripheralUpdatedAdvertisementData(discoveredPeripheral!)
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                    // Response contains number of commissioned EnOcean devices
                    else if arData[2] == 0x02 {
                        if arData[1] < 2 {
                            return
                        }
                        let nrOfEnOceanDevs = arData[3]
                        if nrOfEnOceanDevs > 0 {
                            discoveredPeripheral?.commissionedEnOceanDevice = true
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
                        } else {
                            discoveredPeripheral?.commissionedEnOceanDevice = false
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.black
                        }
                        aCell.peripheralUpdatedAdvertisementData(discoveredPeripheral!)
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                }
                // Generic_Command_Response
                else if arData[0] == 0x05 {
                    if arData[1] < 1 {
                        centralManager.cancelPeripheralConnection(peripheral)
                        return
                    }
                    // Response for Attention Timer has expired
                    if arData[2] == 0x04 {
                        discoveredPeripheral?.blinkingAttentionButton.invalidate()
                        discoveredPeripheral?.activatedAttentionButton.tintColor = UIColor.black
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                    // Response for Attention has started
                    if arData[2] == 0x03 {
                        discoveredPeripheral?.blinkingAttentionButton = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.blinkAttentionButton), userInfo: nil, repeats: true)
                    }
                    // Response for EnOcean radio-based commissioning mode enabled
                    else if arData[2] == 0x01 {
                        discoveredPeripheral?.enabledEnOceanRadioBasedCommissioning = true
                        discoveredPeripheral?.blinkingEnOceanRadioBasedCommissioningButton = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.blinkEnOceanRadioBasedCommissioningButton), userInfo: ["peripheral": discoveredPeripheral], repeats: true)
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                    // Response for EnOcean radio-based commissioning mode disabled
                    else if arData[2] == 0x02 {
                        discoveredPeripheral?.enabledEnOceanRadioBasedCommissioning = false
                        discoveredPeripheral?.blinkingEnOceanRadioBasedCommissioningButton.invalidate()
                        if arData[3] > 0 {
                            discoveredPeripheral?.commissionedEnOceanDevice = true
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.orange
                        } else {
                            discoveredPeripheral?.commissionedEnOceanDevice = false
                            discoveredPeripheral?.enableEnOceanRadioBasedCommissioningButton.tintColor = UIColor.black
                        }
                        centralManager.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
}
