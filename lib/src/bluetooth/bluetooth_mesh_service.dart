import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'ios_ble_peripheral.dart';

/// Callback for peer discovery
typedef PeerDiscoveredCallback = void Function(String peerId, Uint8List? publicKeyDigest);

/// Callback for received messages
typedef MessageReceivedCallback = void Function(String senderId, Uint8List data);

/// BLE Mesh Service for bitchat
/// Implements BLE advertising (peripheral) and scanning (central) functionality
/// Compatible with Swift bitchat implementation
class BluetoothMeshService {
  static final BluetoothMeshService _instance = BluetoothMeshService._internal();
  factory BluetoothMeshService() => _instance;
  BluetoothMeshService._internal();

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  final IOSBlePeripheralService _iosService = IOSBlePeripheralService();

  // Service UUID matching Swift implementation
  static const String serviceUUID = 'F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C';
  static const String characteristicUUID = 'A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D';

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  PeerDiscoveredCallback? onPeerDiscovered;
  MessageReceivedCallback? onMessageReceived;

  bool _isAdvertising = false;
  bool _isScanning = false;
  String? _myPeerID;
  String? _myNickname;

  // Connected devices tracking
  final Set<String> _connectedDevices = <String>{};
  final Map<String, BluetoothDevice> _connectedPeripherals = <String, BluetoothDevice>{};
  final Map<String, List<BluetoothCharacteristic>> _deviceCharacteristics = <String, List<BluetoothCharacteristic>>{};

  /// Start BLE advertising with peripheral service
  /// Note: Android supports manufacturerData, iOS only supports localName/serviceUuid
  /// Compatible with Swift bitchat implementation
  Future<void> startAdvertising({
    required String peerId,
    required String nickname,
    Uint8List? publicKeyDigest,
  }) async {
    if (_isAdvertising) return;
    
    _myPeerID = peerId;
    _myNickname = nickname;
    
    try {
      // Start iOS peripheral service
      try {
        final iosStarted = await _iosService.startService(
          peerID: peerId,
          nickname: nickname,
        );
        if (iosStarted) {
          // Listen for messages from iOS
          _iosService.messageStream.listen((message) {
            final senderId = message['senderId'] as String;
            final payload = message['payload'] as Uint8List;
            
            if (onMessageReceived != null) {
              onMessageReceived!(senderId, payload);
            }
          });
        }
      } catch (e) {
        // iOS BLE peripheral service not available
      }
      
      // Start Android foreground service for persistent advertising
      try {
        const platform = MethodChannel('com.oxchat.lite/ble_service');
        await platform.invokeMethod('startBleService');
      } catch (e) {
        // Android BLE service not available
      }
      
      // Wait for BLE peripheral to be ready (especially important for iOS)
      bool isReady = false;
      int attempts = 0;
      while (!isReady && attempts < 10) {
        try {
          // Check if BLE is supported and ready
          isReady = await _blePeripheral.isSupported;
          if (!isReady) {
            await Future.delayed(Duration(milliseconds: 500));
            attempts++;
          }
        } catch (e) {
          await Future.delayed(Duration(milliseconds: 500));
          attempts++;
        }
      }
      
      if (!isReady) {
        print('BLE peripheral not ready after multiple attempts, continuing anyway...');
      }
      
      // Use same format as Swift: localName = peerID, serviceUUID for discovery
      // Swift expects 8-character peer IDs, so we need to use a 8-char identifier
      final deviceName = peerId.length == 8 ? peerId : peerId.substring(0, 8);
      final advertiseData = AdvertiseData(
        localName: deviceName, // Device name for peerId transmission (matches Swift)
        serviceUuid: serviceUUID, // Same UUID as Swift implementation
        manufacturerId: publicKeyDigest != null ? 0xFFFF : null, // Android only
        manufacturerData: publicKeyDigest, // Android only - for additional data
      );
      
      await _blePeripheral.start(advertiseData: advertiseData);
      _isAdvertising = true;
      
      // Start scanning to discover bitchat peers
      startScanning();
    } catch (e) {
      print('BLE advertising failed: $e');
      rethrow;
    }
  }



  /// Stop BLE advertising
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    
    // Stop iOS peripheral service
    try {
      await _iosService.stopService();
    } catch (e) {
      // iOS BLE peripheral service stop failed
    }
    
    await _blePeripheral.stop();
    _isAdvertising = false;
  }

  /// Start BLE scanning
  /// Uses FlutterBluePlus for cross-platform scanning
  Future<void> startScanning({PeerDiscoveredCallback? onPeer}) async {
    if (_isScanning) {
      return;
    }
    onPeerDiscovered = onPeer;
    
    try {
      // Cancel previous subscription if exists
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      
      // Set up scan results listener first
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) async {
        for (final scanResult in results) {
          final adv = scanResult.advertisementData;
          final peerId = adv.localName ?? scanResult.device.platformName;
          final device = scanResult.device;
          
          // Check if device has our service UUID
          final hasServiceUUID = adv.serviceUuids.any((uuid) => 
            uuid.toString().toUpperCase() == serviceUUID.toUpperCase()
          );
          
          if (!hasServiceUUID) {
            continue;
          }
          
          Uint8List? publicKeyDigest;
          if (adv.manufacturerData.isNotEmpty) {
            final firstData = adv.manufacturerData.values.first;
            publicKeyDigest = Uint8List.fromList(firstData);
          }
          
          // Filter out our own broadcasts and ensure peerId is valid
          if (peerId != null && 
              peerId.isNotEmpty && 
              peerId != _myPeerID &&
              peerId.length == 8) { // Swift only connects to 8-char peer IDs
            if (onPeerDiscovered != null) {
              onPeerDiscovered!(peerId, publicKeyDigest);
            }
            // Auto connect to discovered peer
            await _connectToPeer(peerId, device);
          }
        }
      });
      
      // Start scanning
      await FlutterBluePlus.startScan();
      _isScanning = true;
    } catch (e) {
      print('Failed to start scanning: $e');
      // Clean up on failure
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      // Don't set _isScanning to true if scanning failed
    }
  }

  /// Stop BLE scanning
  Future<void> stopScanning() async {
    if (!_isScanning) return;
    
    try {
      // Stop FlutterBluePlus scanning
      await FlutterBluePlus.stopScan();
    } catch (e) {
      // Error stopping FlutterBluePlus scanning
    }
    
    // Cancel scan results subscription
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
  }



  /// Set message received callback
  void setMessageReceivedCallback(MessageReceivedCallback callback) {
    onMessageReceived = callback;
  }

  /// Get current advertising status
  bool get isAdvertising => _isAdvertising;

  /// Get current scanning status  
  bool get isScanning => _isScanning;

  /// Get my peer ID
  String? get myPeerID => _myPeerID;

  /// Get connected devices count
  int get connectedDevicesCount => _connectedDevices.length;
  
  /// Connect to a discovered peer and subscribe to notify
  Future<void> _connectToPeer(String peerId, BluetoothDevice device) async {
    if (_connectedDevices.contains(peerId)) {
      return;
    }
    try {
      await device.connect(autoConnect: false);
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toUpperCase() == serviceUUID.toUpperCase()) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() == characteristicUUID.toUpperCase()) {
              await characteristic.setNotifyValue(true);
              // Listen for notifications
              characteristic.lastValueStream.listen((value) {
                if (onMessageReceived != null) {
                  onMessageReceived!(peerId, Uint8List.fromList(value));
                }
              });
              _deviceCharacteristics[peerId] = [characteristic];
              break;
            }
          }
          break;
        }
      }
      _connectedDevices.add(peerId);
      _connectedPeripherals[peerId] = device;
    } catch (e) {
      print('Failed to connect to peer $peerId: $e');
    }
  }
  
  /// Send message via BLE
  Future<bool> sendMessage(Uint8List data) async {
    try {
      // Send via iOS peripheral service if available
      try {
        final success = await _iosService.sendMessage(data);
        if (success) {
          return true;
        }
      } catch (e) {
        // iOS peripheral service not available
      }
      
      // Send via Android BLE service if available
      try {
        const platform = MethodChannel('com.oxchat.lite/ble_service');
        final result = await platform.invokeMethod('sendMessage', {'data': data});
        if (result == true) {
          return true;
        }
      } catch (e) {
        // Android BLE service not available
      }
      
      // Send to connected peripherals
      var sentToPeripherals = 0;
      for (final entry in _deviceCharacteristics.entries) {
        final peerId = entry.key;
        final characteristics = entry.value;
        
        for (final characteristic in characteristics) {
          try {
            await characteristic.write(data, withoutResponse: true);
            sentToPeripherals++;
          } catch (e) {
            print('Failed to send message to peripheral $peerId: $e');
          }
        }
      }
      
      if (sentToPeripherals > 0) {
        return true;
      }
      
      print('No BLE service available for sending message');
      return false;
    } catch (e) {
      print('Failed to send message via BLE: $e');
      return false;
    }
  }
} 