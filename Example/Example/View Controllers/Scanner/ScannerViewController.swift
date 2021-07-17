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
        case enableEnOceanRadiobasedCommissioning = 3
        case disableEnOceanRadiobasedCommissioning = 4
        case triggerDeviceAttention = 5
    }
    
    private var command = DtRxMessageType.undefined
    
    private var activatedAttentionButton = UIButton()

    @IBAction func aboutTapped(_ sender: UIBarButtonItem) {
        let rootViewController = navigationController as? RootViewController
        rootViewController?.showIntro(animated: true)
    }

    @IBAction func aboutTappedAttentionButton(_ sender: UIButton) {
        activatedAttentionButton = sender
        sender.tintColor = UIColor.orange
        
        var superview = sender.superview
        while let view = superview, !(view is UITableViewCell) {
            superview = view.superview
        }
        guard let cell = superview as? UITableViewCell else {
            print("button is not contained in a table view cell")
            return
        }
        guard let indexPath = tableView.indexPath(for: cell) else {
            print("failed to get index path for cell containing button")
            return
        }
        // We've got the index path for the cell that contains the button,
        // now go for sending attention message to corresponding peripheral
        print("button is in row \(indexPath.row)")
        
        let peripheral = filteredPeripherals[indexPath.row].basePeripheral
        command = DtRxMessageType.triggerDeviceAttention
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
        print("\nScannerViewController connected\n")
        peripheral.delegate = self
        peripheral.discoverServices([ScannerViewController.DTS_SERVICE])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("\nScannerViewController disconnected\n")
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
            print("Central is not powered on")
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
            print("ScannerViewController didDiscoverServices error!")
            command = DtRxMessageType.undefined
            return
        }
        guard peripheral.services?.count != 0 else {
            print("ScannerViewController didDiscoverServices none")
            command = DtRxMessageType.undefined
            return
        }
        let s = peripheral.services?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"
        print("ScannerViewController didDiscoverServices:")
        print(s)
        guard let services = peripheral.services else {
            print("ScannerViewController missing service")
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
            print("ScannerViewController didDiscoverCharacteristicsFor error!")
            return
        }
        guard let characteristics = service.characteristics else {
            print("ScannerViewController missing characteristics")
            return
        }

        let c = service.characteristics?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"
        print("ScannerViewController didDiscoverCharacteristicsFor:")
        print(c)

        for characteristic in characteristics {
            if characteristic.uuid == ScannerViewController.DTS_CHARACTERISTIC_RX {
                var data = Data()
                switch command {
                    case .requestForBdAddr:
                        data = Data([0x01, 0x01, 0x01])
                        print("Writing requestForBdAddr to DTS_CHARACTERISTIC_RX")
                        break
                    case .requestForBdAddrInitial:
                        data = Data([0x01, 0x01, 0x01])
                        print("Writing requestForBdAddrInitial to DTS_CHARACTERISTIC_RX")
                        break
                    case .enableEnOceanRadiobasedCommissioning:
                        data = Data([0x02, 0x01, 0x01])
                        print("Writing enableEnOceanRadiobasedCommissioning to DTS_CHARACTERISTIC_RX")
                        break
                    case .disableEnOceanRadiobasedCommissioning:
                        data = Data([0x02, 0x01, 0x02])
                        print("Writing disableEnOceanRadiobasedCommissioning to DTS_CHARACTERISTIC_RX")
                        break
                    case .triggerDeviceAttention:
                        data = Data([0x02, 0x01, 0x03])
                        print("Writing triggerDeviceAttention to DTS_CHARACTERISTIC_RX")
                        break
                    case .undefined:
                        print("undefined command")
                        break
                }
                if !data.isEmpty {
                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                }
            }
            else if characteristic.uuid == ScannerViewController.DTS_CHARACTERISTIC_TX {
                if characteristic.properties.contains(.notify) {
                    print("Enabling notifications for DTS_CHARACTERISTIC_TX")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        
        print("didUpdateNotificationStateFor \(characteristic.uuid)")
        
        // Check for error.
        guard error == nil else {
            print("Error didUpdateNotificationStateFor")
            return
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        
        print("didUpdateValueFor \(characteristic.uuid)")
        
        // Check for error.
        guard error == nil else {
            return
        }
        guard let data = characteristic.value else {
            print("Error no characteristic value")
            return
        }

        let arData = Array(data)

        let discoveredPeripheral = discoveredPeripherals.first(where: { $0.basePeripheral.identifier == peripheral.identifier })
        if let index = filteredPeripherals.firstIndex(of: discoveredPeripheral!) {
            // Update the cell views directly, without refreshing the whole table.
            if let aCell = tableView.cellForRow(at: [0, index]) as? ScannerTableViewCell {
                // Generic_Request_Response
                if arData[0] == 0x04 {
                    // Response contains BBD_ADDR
                    if arData[2] == 0x01 {
                        if arData[1] < 5 {
                            print("Error invalid data")
                            return
                        }
                        discoveredPeripheral?.bd_addr = String(format: " %02x%02x", arData[3], arData[4])
                        aCell.peripheralUpdatedAdvertisementData(discoveredPeripheral!)
                        centralManager.cancelPeripheralConnection(peripheral)
                        command = DtRxMessageType.undefined
                    }
                }
                // Generic_Command_Response
                else if arData[0] == 0x05 {
                    // Response for Attention Timer has expired
                    if arData[2] == 0x04 {
                        if arData[1] < 1 {
                            print("Error invalid data")
                            return
                        }
                        activatedAttentionButton.tintColor = UIColor.darkGray
                        centralManager.cancelPeripheralConnection(peripheral)
                        command = DtRxMessageType.undefined
                    }
                }
            }
        }
    }
}
