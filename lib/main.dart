import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:fluttertoast/fluttertoast.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SirenaMap',
      theme: ThemeData(
        primaryColor: const Color(0xFF003DA5),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF003DA5)),
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class PathPainter extends CustomPainter {
  final List<Offset> points;

  PathPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final paint = Paint()
      ..color = const Color(0xFF388E3C)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final shadowPaint = Paint()
      ..color = const Color(0x4D000000)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);

    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];

      final controlPoint = Offset(
        (p0.dx + p1.dx) / 2,
        (p0.dy + p1.dy) / 2,
      );

      final endPoint = Offset(
        (p1.dx + p2.dx) / 2,
        (p1.dy + p2.dy) / 2,
      );
      path.quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        endPoint.dx,
        endPoint.dy,
      );
    }

    if (points.length >= 2) {
      path.lineTo(points.last.dx, points.last.dy);
    }

    canvas.drawPath(path, shadowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant PathPainter oldDelegate) => true;
}

class Node {
  final int x, y;
  double g, h, f;
  Node? parent;

  Node(this.x, this.y, this.g, this.h) : f = g + h;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final List<DiscoveredDevice> _devices = [];
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<BleStatus>? _statusSubscription;
  bool _isScanning = false;
  bool _hasPermissions = false;
  final int _rssiThreshold = -80;
  int _deviceCount = 0;
  final Map<String, List<double>> _distanceHistory = {};
  final Map<String, DateTime> _lastSeen = {};
  static const double realWidthMeters = 15.0;
  static const double realHeightMeters = 25.0;
  Map<String, double> _lastClientPosMeters = {'x': 7.5, 'y': 12.5};
  bool _showGondolas = true;
  bool _showRouteDialog = false;
  bool _hasArrived = false;
  bool _highlightDetails = false;
  bool _autoMode = false;

  final List<double> pasilloCentersXMeters = [0.5, 4.5, 8.5, 12.5, 14.5];

  final List<Map<String, dynamic>> _products = [
    {'name': 'Kiwi', 'x': 4.5, 'y': 5.0, 'emoji': '🥝', 'category': 'FRUTAS Y VERDURAS', 'location': 'Pasillo 2, Góndola G3'},
    {'name': 'Carnes', 'x': 8.5, 'y': 18.0, 'emoji': '🍖', 'category': 'CARNES', 'location': 'Pasillo 4, Góndola G10', 'isGroup': true, 'isCategory': true},
    {
      'name': 'Bebidas',
      'x': 12.5,
      'y': 15.0,
      'emoji': '🥤',
      'category': 'BEBIDAS',
      'location': 'Pasillo 5, Góndola G13',
      'isGroup': true,
      'subProducts': [
        {'name': 'Agua', 'category': 'BEBIDAS', 'location': 'Pasillo 5, Góndola G13'},
        {'name': 'Jugo de naranja', 'category': 'BEBIDAS', 'location': 'Pasillo 5, Góndola G13'},
        {'name': 'Monster', 'category': 'BEBIDAS', 'location': 'Pasillo 5, Góndola G13'},
        {'name': 'Coca Cola', 'category': 'BEBIDAS', 'location': 'Pasillo 5, Góndola G13'},
      ]
    },
  ];

  Map<String, dynamic>? _selectedProduct;
  Map<String, double>? _currentTargetPos;

  static const double gridSize = 0.5;

  int _selectedIndex = 3;

  Timer? _updateTimer;
  Timer? _shoppingTimer;
  Duration _elapsedTime = Duration.zero;
  bool _isTimerRunning = false;

  final Map<String, bool?> _productStatus = {};

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _requestAllPermissions();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_currentTargetPos != null && mounted) {
        _checkProximityToTarget();
        if (_isTimerRunning) {
          setState(() {
            _elapsedTime = Duration(seconds: _elapsedTime.inSeconds + 1);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _shoppingTimer?.cancel();
    _scanSubscription?.cancel();
    _statusSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startShoppingTimer() {
    if (!_isTimerRunning) {
      setState(() {
        _isTimerRunning = true;
        _elapsedTime = Duration.zero;
      });
    }
  }

  void _stopShoppingTimer() {
    if (_isTimerRunning) {
      setState(() {
        _isTimerRunning = false;
      });
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '${hours}h ${minutes}m ${seconds}s'
        : '${minutes}m ${seconds}s';
  }

  bool _isCompleted(Map<String, dynamic> product) {
    if (product['isCategory'] == true && product['isGroup'] == true) {
      return true;
    }
    if (product['subProducts'] != null) {
      return (product['subProducts'] as List<Map<String, dynamic>>)
          .every((sub) => _productStatus[sub['name']] != null);
    } else {
      return _productStatus[product['name']] != null;
    }
  }

  bool _hasChecks(Map<String, dynamic> product) {
    return !(product['isCategory'] == true && product['isGroup'] == true);
  }

  void _findAndSetNextProduct() {
    final incomplete = _products.where((p) => !_isCompleted(p)).toList();
    if (incomplete.isEmpty) {
      setState(() {
        _autoMode = false;
        _currentTargetPos = null;
        _selectedProduct = null;
      });
      Fluttertoast.showToast(
        msg: '¡Lista de compras completada!',
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }

    final clientX = _lastClientPosMeters['x']!;
    final clientY = _lastClientPosMeters['y']!;

    Map<String, dynamic>? closest;
    double minDist = double.infinity;

    for (var p in incomplete) {
      final dx = (p['x'] as double) - clientX;
      final dy = (p['y'] as double) - clientY;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < minDist) {
        minDist = dist;
        closest = p;
      }
    }

    if (closest != null) {
      final nonNullClosest = closest; // ya no es nullable

      setState(() {
        _selectedProduct = nonNullClosest;
        _currentTargetPos = {
          'x': nonNullClosest['x'] as double,
          'y': nonNullClosest['y'] as double,
        };
        _hasArrived = false;
        _showRouteDialog = false;
      });

      _startShoppingTimer();
    }
  }

  void _toggleAutoMode() {
    setState(() {
      _autoMode = !_autoMode;
    });
    if (_autoMode) {
      if (_currentTargetPos == null || _hasArrived) {
        _findAndSetNextProduct();
      }
    } else {
      // Optionally stop current if needed, but keep manual
    }
  }

  void _checkProximityToTarget() {
    if (_currentTargetPos == null || _hasArrived) return;

    final double dx = _lastClientPosMeters['x']! - _currentTargetPos!['x']!;
    final double dy = _lastClientPosMeters['y']! - _currentTargetPos!['y']!;
    final double distance = math.sqrt(dx * dx + dy * dy);

    if (distance <= 0.5) {
      setState(() {
        _hasArrived = true;
        _stopShoppingTimer();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.green.shade500, Colors.green.shade700],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.4),
                  blurRadius: 20,
                  spreadRadius: 0,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_circle,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '¡Has llegado!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          duration: const Duration(seconds: 5),
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            MediaQuery.of(context).size.width * 0.1,
            0,
            MediaQuery.of(context).size.width * 0.1,
            120,
          ),
        ),
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });

      setState(() {
        _highlightDetails = true;
      });
      Future.delayed(Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _highlightDetails = false;
          });
        }
      });

      if (_autoMode && _selectedProduct != null && !_hasChecks(_selectedProduct!)) {
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _autoMode) {
            _findAndSetNextProduct();
          }
        });
      }

      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() {
            _hasArrived = false;
          });
        }
      });
    }
  }

  Future<void> _requestAllPermissions() async {
    debugPrint('Solicitando permisos...');

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    bool locationGranted = statuses[Permission.location]?.isGranted == true ||
        statuses[Permission.locationWhenInUse]?.isGranted == true;

    debugPrint('Estado de permisos:');
    debugPrint('- Ubicación: $locationGranted');

    if (locationGranted) {
      setState(() {
        _hasPermissions = true;
      });
      _checkBleStatus();
    } else {
      debugPrint('Permisos de ubicación no otorgados');
      _showPermissionDialog();
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permisos Necesarios'),
        content: const Text(
            'Esta aplicación necesita permisos de ubicación y Bluetooth para detectar beacons cercanos. '
                'Por favor, concede los permisos en la configuración de la aplicación.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('Abrir Configuración'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _requestAllPermissions();
            },
            child: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }

  void _checkBleStatus() {
    _statusSubscription = _ble.statusStream.listen((status) {
      debugPrint('BLE Status: $status');
      if (status == BleStatus.ready) {
        _startScan();
      } else if (status == BleStatus.unauthorized) {
        debugPrint('Se requieren permisos de Bluetooth');
      } else if (status == BleStatus.poweredOff) {
        debugPrint('Bluetooth está apagado');
        _showBluetoothOffDialog();
      }
    });
  }

  void _showBluetoothOffDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bluetooth Desactivado'),
        content: const Text('Por favor, activa el Bluetooth para detectar beacons.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _startScan() {
    if (_isScanning || !_hasPermissions) return;

    debugPrint('=== INICIANDO ESCANEO BLE ===');
    setState(() {
      _isScanning = true;
      _devices.clear();
      _deviceCount = 0;
      _distanceHistory.clear();
      _lastSeen.clear();
      _lastClientPosMeters = {'x': realWidthMeters / 2, 'y': realHeightMeters / 2};
    });

    _scanSubscription = _ble.scanForDevices(
      withServices: [],
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: true,
    ).listen((device) {
      _deviceCount++;
      debugPrint('>>> Dispositivo #$_deviceCount encontrado: "${device.name}" (${device.id}) - RSSI: ${device.rssi}');

      if (device.rssi > _rssiThreshold) {
        debugPrint('✓ Dispositivo cumple filtro RSSI (>${_rssiThreshold}dBm)');

        setState(() {
          final existingIndex = _devices.indexWhere((d) => d.id == device.id);
          if (existingIndex != -1) {
            debugPrint('→ Actualizando dispositivo existente');
            _devices[existingIndex] = device;
          } else {
            _devices.add(device);
            debugPrint('✓ NUEVO DISPOSITIVO AGREGADO A LA LISTA UI: ${device.name.isNotEmpty ? device.name : "Sin nombre"} - ${device.id}');
            debugPrint('→ Total dispositivos en lista: ${_devices.length}');
          }

          final distance = _calculateDistance(device.rssi);
          if (_isEsp32(device)) {
            _distanceHistory[device.id] ??= [];
            _distanceHistory[device.id]!.add(distance);
            if (_distanceHistory[device.id]!.length > 10) {
              _distanceHistory[device.id]!.removeAt(0);
            }
            _lastSeen[device.id] = DateTime.now();
          }
        });
      } else {
        debugPrint('✗ Dispositivo filtrado por RSSI débil (${device.rssi} <= ${_rssiThreshold}dBm)');
      }
    }, onError: (error) {
      debugPrint('❌ Error scanning: $error');
      setState(() => _isScanning = false);

      String errorMsg = 'Error de escaneo desconocido';
      if (error.toString().contains('Location Permission missing')) {
        errorMsg = 'Faltan permisos de ubicación. Ve a Configuración > Aplicaciones > Smart Supermarket > Permisos y activa "Ubicación"';
      } else if (error.toString().contains('Bluetooth disabled')) {
        errorMsg = 'Bluetooth desactivado. Activa el Bluetooth para continuar';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMsg),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Configuración',
            textColor: Colors.white,
            onPressed: () => openAppSettings(),
          ),
        ),
      );

      Timer(const Duration(seconds: 5), () {
        if (!_isScanning) {
          _startScan();
        }
      });
    });

    Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (!_isScanning) {
        timer.cancel();
      } else {
        setState(() {});
      }
    });
  }

  void _stopScan() {
    debugPrint('=== DETENIENDO ESCANEO BLE ===');
    debugPrint('Dispositivos finales en lista: ${_devices.length}');
    _scanSubscription?.cancel();
    setState(() => _isScanning = false);
  }

  double _calculateDistance(int rssi) {
    if (rssi == 0) return -1.0;

    const txPower = -59;
    final ratio = rssi * 1.0 / txPower;

    if (ratio < 1.0) {
      return math.pow(ratio, 10).toDouble();
    } else {
      return (0.89976 * math.pow(ratio, 7.7095) + 0.111).toDouble();
    }
  }

  double _getSmoothedDistance(String deviceId) {
    final history = _distanceHistory[deviceId];
    if (history == null || history.isEmpty) return -1.0;
    return history.reduce((a, b) => a + b) / history.length;
  }

  bool _isInGondola(double x, double y, List<Map<String, dynamic>> gondolasMeters) {
    for (var gondola in gondolasMeters) {
      final rect = Rect.fromLTWH(
        gondola['x'],
        gondola['y'],
        gondola['width'],
        gondola['height'],
      );
      if (rect.contains(Offset(x, y))) {
        debugPrint('⚠️ Posición inválida: dentro de góndola ${gondola['id']}');
        return true;
      }
    }
    return false;
  }

  double _snapToPasilloX(double x, double y) {
    final gondolas = _getGondolasMeters();
    if (pasilloCentersXMeters.isEmpty) return x;

    var candidates = pasilloCentersXMeters.where((center) => !_isInGondola(center, y, gondolas)).toList();

    if (candidates.isEmpty) {
      debugPrint('⚠️ No hay pasillos libres en y=$y');
      return x;
    }

    return candidates.reduce((a, b) => (x - a).abs() < (x - b).abs() ? a : b);
  }

  Map<String, double> trilaterate(
      List<Map<String, double>> beacons,
      Map<int, double> distances,
      ) {
    final int n = beacons.length;
    if (n < 3 || distances.length < 3) {
      debugPrint('⚠️ No hay suficientes beacons para trilateración');
      return _lastClientPosMeters;
    }

    // Filtrar distancias válidas > 0
    List<Map<String, double>> validBeacons = [];
    List<double> validDistances = [];
    for (int i = 0; i < n; i++) {
      if (distances.containsKey(i) && distances[i]! > 0) {
        validBeacons.add(beacons[i]);
        validDistances.add(distances[i]!);
      }
    }

    if (validBeacons.length < 3) {
      return _lastClientPosMeters;
    }

    // Removed proximity snap to allow more accurate positions near products

    double rawX, rawY;

    if (validBeacons.length == 3) {
      // Método exacto para 3 beacons
      var p1 = validBeacons[0];
      var p2 = validBeacons[1];
      var p3 = validBeacons[2];

      double r1 = validDistances[0];
      double r2 = validDistances[1];
      double r3 = validDistances[2];

      debugPrint('📍 Trilaterando con distancias: r1=$r1, r2=$r2, r3=$r3');

      double A = 2 * (p2['x']! - p1['x']!);
      double B = 2 * (p2['y']! - p1['y']!);
      double C = 2 * (p3['x']! - p1['x']!);
      double D = 2 * (p3['y']! - p1['y']!);

      double E = r1 * r1 - r2 * r2 - p1['x']! * p1['x']! - p1['y']! * p1['y']! +
          p2['x']! * p2['x']! + p2['y']! * p2['y']!;
      double F = r1 * r1 - r3 * r3 - p1['x']! * p1['x']! - p1['y']! * p1['y']! +
          p3['x']! * p3['x']! + p3['y']! * p3['y']!;

      double denom = A * D - B * C;
      if (denom == 0) {
        debugPrint('⚠️ Denominador cero en trilateración, usando última posición');
        return _lastClientPosMeters;
      }

      rawX = (E * D - B * F) / denom;
      rawY = (A * F - E * C) / denom;
    } else {
      // Para más de 3, usar gradient descent para minimizar least squares
      // Initial guess: average of beacon positions
      rawX = validBeacons.map((b) => b['x']!).reduce((a, b) => a + b) / validBeacons.length;
      rawY = validBeacons.map((b) => b['y']!).reduce((a, b) => a + b) / validBeacons.length;

      const double learningRate = 0.01;
      const int maxIterations = 1000;
      const double tolerance = 0.001;

      for (int iter = 0; iter < maxIterations; iter++) {
        double gradX = 0.0;
        double gradY = 0.0;

        for (int i = 0; i < validBeacons.length; i++) {
          double bx = validBeacons[i]['x']!;
          double by = validBeacons[i]['y']!;
          double dMeas = validDistances[i];
          double dCalc = math.sqrt((rawX - bx) * (rawX - bx) + (rawY - by) * (rawY - by));
          if (dCalc == 0) continue;
          gradX += 2 * (dCalc - dMeas) * (rawX - bx) / dCalc;
          gradY += 2 * (dCalc - dMeas) * (rawY - by) / dCalc;
        }

        double newX = rawX - learningRate * gradX;
        double newY = rawY - learningRate * gradY;

        if ((newX - rawX).abs() < tolerance && (newY - rawY).abs() < tolerance) {
          break;
        }

        rawX = newX;
        rawY = newY;
      }
    }

    // Aplicar suavizado exponencial para movimiento más fluido
    const double smoothingAlpha = 0.3; // Ajusta entre 0 y 1; menor = más suave pero más lag
    double x = smoothingAlpha * rawX + (1 - smoothingAlpha) * _lastClientPosMeters['x']!;
    double y = smoothingAlpha * rawY + (1 - smoothingAlpha) * _lastClientPosMeters['y']!;

    x = math.max(0, math.min(realWidthMeters, x));
    y = math.max(0, math.min(realHeightMeters, y));

    double deltaX = (x - _lastClientPosMeters['x']!).abs();
    double deltaY = (y - _lastClientPosMeters['y']!).abs();
    const double positionThreshold = 0.8;
    if (deltaX < positionThreshold && deltaY < positionThreshold) {
      debugPrint('📍 Cambio de posición demasiado pequeño, manteniendo última posición');
      return _lastClientPosMeters;
    }

    if (_isInGondola(x, y, _getGondolasMeters())) {
      debugPrint('📍 Posición en góndola, manteniendo última posición válida');
      return _lastClientPosMeters;
    }

    x = _snapToPasilloX(x, y);

    _lastClientPosMeters = {'x': x, 'y': y};
    debugPrint('📍 Posición calculada: x=$x, y=$y');
    return _lastClientPosMeters;
  }

  List<Map<String, dynamic>> _getGondolasMeters() {
    return const [
      {'id': 'Border', 'x': 0.0, 'y': 0.0, 'width': 14.63, 'height': 2.70},
      {'id': 'G1', 'x': 1.53, 'y': 3.89, 'width': 1.85, 'height': 7.24},
      {'id': 'G2', 'x': 4.30, 'y': 10.78, 'width': 1.09, 'height': 0.37},
      {'id': 'G3', 'x': 5.53, 'y': 4.125, 'width': 0.72, 'height': 5.9},
      {'id': 'G4', 'x': 6.89, 'y': 4.125, 'width': 0.638, 'height': 6.7},
      {'id': 'G5', 'x': 8.22, 'y': 4.125, 'width': 0.62, 'height': 6.24},
      {'id': 'G6', 'x': 9.57, 'y': 4.125, 'width': 0.63, 'height': 6.81},
      {'id': 'G7', 'x': 10.86, 'y': 4.125, 'width': 0.63, 'height': 6.81},
      {'id': 'G8', 'x': 5.1, 'y': 13.06, 'width': 0.75, 'height': 7.4},
      {'id': 'G9', 'x': 6.59, 'y': 13.06, 'width': 0.55, 'height': 7.4},
      {'id': 'G10', 'x': 7.9, 'y': 13.06, 'width': 0.53, 'height': 7.4},
      {'id': 'G11', 'x': 9.14, 'y': 13.06, 'width': 0.53, 'height': 7.4},
      {'id': 'G12', 'x': 10.33, 'y': 13.06, 'width': 0.53, 'height': 7.4},
      {'id': 'G13', 'x': 11.7, 'y': 13.06, 'width': 0.53, 'height': 7.4},
      {'id': 'G14', 'x': 1.8, 'y': 13.0, 'width': 1.78, 'height': 1.0},
      {'id': 'G15', 'x': 1.7, 'y': 15.15, 'width': 1.95, 'height': 0.99},
      {'id': 'G16', 'x': 0.9, 'y': 17.08, 'width': 2.58, 'height': 1.17},
      {'id': 'G17', 'x': 0.66, 'y': 19.53, 'width': 2.87, 'height': 0.95},
    ];
  }

  String _getDeviceTypeIcon(DiscoveredDevice device) {
    final name = device.name.toLowerCase();
    final macAddress = device.id.toLowerCase();

    if (name.contains('esp') || name.contains('beacon') || macAddress.startsWith('e4:b3:23')) {
      return '📡';
    } else if (name.contains('phone') || name.contains('iphone') || name.contains('samsung')) {
      return '📱';
    } else if (name.contains('watch')) {
      return '⌚';
    } else {
      return '📶';
    }
  }

  bool _isEsp32(DiscoveredDevice device) {
    final name = device.name.toLowerCase();
    final macAddress = device.id.toLowerCase();
    return name.contains('esp') || macAddress.startsWith('e4:b3:23');
  }

  double heuristic(math.Point<int> a, math.Point<int> b) {
    double dx = (a.x - b.x).abs().toDouble();
    double dy = (a.y - b.y).abs().toDouble();
    return math.sqrt(dx * dx + dy * dy) * gridSize;
  }

  List<Offset> findPathMeters(
      double startX,
      double startY,
      double goalX,
      double goalY,
      List<Map<String, dynamic>> gondolas,
      ) {
    int gridW = (realWidthMeters / gridSize).ceil();
    int gridH = (realHeightMeters / gridSize).ceil();

    List<List<bool>> blocked = List.generate(gridH, (_) => List.filled(gridW, false));

    for (var g in gondolas) {
      int left = (g['x'] / gridSize).floor();
      int top = (g['y'] / gridSize).floor();
      int right = ((g['x'] + g['width']) / gridSize).ceil();
      int bottom = ((g['y'] + g['height']) / gridSize).ceil();

      for (int gy = top; gy < bottom; gy++) {
        for (int gx = left; gx < right; gx++) {
          if (gx >= 0 && gx < gridW && gy >= 0 && gy < gridH) {
            blocked[gy][gx] = true;
          }
        }
      }
    }

    math.Point<int> startP = math.Point((startX / gridSize).floor(), (startY / gridSize).floor());
    math.Point<int> goalP = math.Point((goalX / gridSize).floor(), (goalY / gridSize).floor());

    if (blocked[startP.y][startP.x] || blocked[goalP.y][goalP.x]) return [];

    List<Node> open = [];
    Set<math.Point<int>> closed = {};

    Node startNode = Node(startP.x, startP.y, 0, heuristic(startP, goalP));
    open.add(startNode);

    while (open.isNotEmpty) {
      open.sort((a, b) => a.f.compareTo(b.f));
      Node curr = open.removeAt(0);
      math.Point<int> currP = math.Point(curr.x, curr.y);
      closed.add(currP);

      if (currP == goalP) {
        List<Offset> path = [];
        Node? c = curr;
        while (c != null) {
          path.add(Offset((c.x + 0.5) * gridSize, (c.y + 0.5) * gridSize));
          c = c.parent;
        }
        path = path.reversed.toList();
        return path;
      }

      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          if (dx == 0 && dy == 0) continue;
          int nx = curr.x + dx;
          int ny = curr.y + dy;
          if (nx < 0 || nx >= gridW || ny < 0 || ny >= gridH || blocked[ny][nx]) continue;

          math.Point<int> np = math.Point(nx, ny);
          if (closed.contains(np)) continue;

          double dist = math.sqrt((dx * dx + dy * dy).toDouble()) * gridSize;
          double tentG = curr.g + dist;

          int neighborIndex = open.indexWhere((n) => n.x == nx && n.y == ny);
          Node neigh;

          if (neighborIndex == -1) {
            double h = heuristic(np, goalP);
            neigh = Node(nx, ny, tentG, h);
            neigh.parent = curr;
            open.add(neigh);
          } else {
            neigh = open[neighborIndex];
            if (tentG < neigh.g) {
              neigh.g = tentG;
              neigh.f = tentG + neigh.h;
              neigh.parent = curr;
            }
          }
        }
      }
    }
    return [];
  }

  double calculatePathLength(List<Offset> path) {
    if (path.isEmpty || path.length < 2) return 0.0;
    double length = 0.0;
    for (int i = 0; i < path.length - 1; i++) {
      final dx = path[i + 1].dx - path[i].dx;
      final dy = path[i + 1].dy - path[i].dy;
      length += math.sqrt(dx * dx + dy * dy);
    }
    return length;
  }

  void _toggleRoute() {
    setState(() {
      if (_currentTargetPos != null &&
          _currentTargetPos!['x'] == _selectedProduct?['x'] &&
          _currentTargetPos!['y'] == _selectedProduct?['y']) {
        _currentTargetPos = null;
        _stopShoppingTimer();
      } else {
        _currentTargetPos = {
          'x': _selectedProduct!['x'] as double,
          'y': _selectedProduct!['y'] as double,
        };
        _startShoppingTimer();
      }
      _showRouteDialog = false;
      _hasArrived = false;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _onCheckChanged(String name, bool? value) {
    setState(() {
      _productStatus[name] = value;
    });

    // Guardar inmediatamente (aquí simulado, puedes integrar Firebase o SharedPreferences)
    print('Item $name actualizado: found = $value');

    // Mostrar toast sutil
    Fluttertoast.showToast(
      msg: 'Cambios guardados',
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );

    if (_autoMode && _selectedProduct != null && _hasArrived && _isCompleted(_selectedProduct!)) {
      _findAndSetNextProduct();
    }
  }

  @override
  Widget build(BuildContext context) {
    final gondolasMeters = _getGondolasMeters();

    final double mapWidth = MediaQuery.of(context).size.width - 32;
    final double mapHeight = 500.0;
    final double dotSize = 12.0;
    final double fixedX = (mapWidth - dotSize) / 2;
    final double fixedY = (mapHeight - dotSize) / 2;

    final List<Map<String, double>> beaconPositionsPixels = [
      {'x': (3.6 / 15.0) * 360, 'y': (5.0 / 25.0) * 500}, // ~ (72.0, 80.0)
      {'x': (10.4 / 15.0) * 360, 'y': (6.0 / 25.0) * 500}, // ~ (288.0, 80.0)
      {'x': (3.6 / 15.0) * 360, 'y': (11.0 / 25.0) * 500}, // ~ (72.0, 320.0)
      {'x': (11.0 / 15.0) * 360, 'y': (16.0 / 25.0) * 500}, // ~ (288.0, 320.0)
    ];

    final List<Map<String, double>> beaconPositionsMeters = beaconPositionsPixels.map((pos) {
      return {
        'x': pos['x']! / mapWidth * realWidthMeters,
        'y': pos['y']! / mapHeight * realHeightMeters,
      };
    }).toList();

    final List<Rect> gondolasPixels = gondolasMeters.map((gondola) {
      return Rect.fromLTWH(
        gondola['x'] / realWidthMeters * mapWidth,
        gondola['y'] / realHeightMeters * mapHeight,
        gondola['width'] / realWidthMeters * mapWidth,
        gondola['height'] / realHeightMeters * mapHeight,
      );
    }).toList();

    final espDevices = _devices
        .where((d) => _isEsp32(d) && _lastSeen.containsKey(d.id) && DateTime.now().difference(_lastSeen[d.id]!) < const Duration(seconds: 15))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    final Map<int, double> beaconDistances = {
      for (int i = 0; i < espDevices.length; i++)
        i: _getSmoothedDistance(espDevices[i].id),
    };

    final bool useDynamicPosition = espDevices.length >= 3 && beaconDistances.values.every((d) => d > 0);

    final Map<String, double> clientPosMeters = trilaterate(beaconPositionsMeters.take(espDevices.length).toList(), beaconDistances);

    final double clientXPixel = clientPosMeters['x']! / realWidthMeters * mapWidth;
    final double clientYPixel = clientPosMeters['y']! / realHeightMeters * mapHeight;

    double clampedX = useDynamicPosition ? math.max(0, math.min(mapWidth - dotSize, clientXPixel)) : fixedX;
    double clampedY = useDynamicPosition ? math.max(0, math.min(mapHeight - dotSize, clientYPixel)) : fixedY;

    List<Offset> pathPixels = [];
    if (_currentTargetPos != null) {
      final pathMeters = findPathMeters(
        clientPosMeters['x']!,
        clientPosMeters['y']!,
        _currentTargetPos!['x']!,
        _currentTargetPos!['y']!,
        gondolasMeters,
      );
      pathPixels = pathMeters.map((o) => Offset(
        o.dx / realWidthMeters * mapWidth,
        o.dy / realHeightMeters * mapHeight,
      )).toList();
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(70.0),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFFD100), Color(0xFFFFC107)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x26000000),
                offset: Offset(0, 2),
                blurRadius: 8.0,
                spreadRadius: 0,
              ),
            ],
          ),
          child: SafeArea(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.1),
                    Colors.white.withOpacity(0.05),
                  ],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withOpacity(0.1),
                    width: 0.5,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    // Logo izquierdo - mismo ancho que el botón derecho
                    SizedBox(
                      width: 45,
                      height: 45,
                      child: Center(
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                          height: 33,
                          width: 45,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              alignment: Alignment.center,
                              child: const Text(
                                'LA SIRENA',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    // Contenido central - perfectamente centrado
                    Expanded(
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.location_on_rounded,
                                color: Colors.black87,
                                size: 14,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Sirena Lope de Vega',
                              style: TextStyle(
                                color: Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Botón derecho - mismo ancho que el logo
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            setState(() {
                              _showGondolas = !_showGondolas;
                            });
                          },
                          child: const Icon(
                            Icons.person_rounded,
                            color: Colors.black87,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),

      body: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16.0, left: 20.0, right: 20.0, bottom: 0.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.store_mall_directory_rounded,
                    color: Color(0xFF2E7D32),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      'Mapa de la Tienda',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF121212),
                        letterSpacing: 0.3,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.all(20),
              height: 520,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    spreadRadius: 3,
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(
                        'assets/images/plano_supermercado.png',
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          debugPrint('❌ Error cargando imagen del mapa: $error');
                          debugPrint('📁 Ruta intentada: assets/images/plano_supermercado.png');
                          return Container(
                            color: const Color(0xFFF5F7FA),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.image_not_supported,
                                    size: 48,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'No se pudo cargar el mapa',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Verifica la ruta de la imagen',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    ...gondolasPixels.asMap().entries.map((entry) {
                      int index = entry.key;
                      Rect gondola = entry.value;
                      return Positioned(
                        left: gondola.left,
                        top: gondola.top,
                        width: gondola.width,
                        height: gondola.height,
                        child: Container(
                          decoration: BoxDecoration(
                            color: _showGondolas
                                ? Colors.blueAccent.withOpacity(0.25)
                                : Colors.transparent,
                            border: _showGondolas
                                ? Border.all(color: Colors.blueAccent.withOpacity(0.4), width: 1.5)
                                : null,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: _showGondolas
                              ? Center(
                            child: Text(
                              gondolasMeters[index]['id'],
                              style: TextStyle(
                                color: Colors.blueAccent.withOpacity(0.9),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          )
                              : null,
                        ),
                      );
                    }),
                    CustomPaint(
                      size: Size(mapWidth, mapHeight),
                      painter: PathPainter(pathPixels),
                    ),
                    if (_currentTargetPos != null)
                      Positioned(
                        left: _currentTargetPos!['x']! / realWidthMeters * mapWidth - dotSize / 2,
                        top: _currentTargetPos!['y']! / realHeightMeters * mapHeight - dotSize / 2,
                        child: Container(
                          width: dotSize,
                          height: dotSize,
                          decoration: BoxDecoration(
                            color: Colors.green.shade600,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.green.withOpacity(0.4),
                                spreadRadius: 2,
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ..._products.map((prod) {
                      double px = (prod['x'] as double) / realWidthMeters * mapWidth - 15;
                      double py = (prod['y'] as double) / realHeightMeters * mapHeight - 15;
                      Color borderColor = prod['name'] == 'Carnes' ? Colors.blueAccent : const Color(0xFFFFD100);
                      return Positioned(
                        left: px,
                        top: py,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedProduct = prod;
                              _showRouteDialog = true;
                            });
                          },
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: borderColor, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  spreadRadius: 1,
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                prod['emoji'] as String,
                                style: TextStyle(fontSize: 18, color: Colors.blueGrey.shade700),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 500),
                      left: clampedX,
                      top: clampedY,
                      child: Container(
                        width: dotSize + 5,
                        height: dotSize + 5,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.3),
                            width: 3,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Container(
                          width: dotSize - 10,
                          height: dotSize - 10,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.yellow, Colors.yellow.withOpacity(0.7)],
                              begin: Alignment.center,
                              end: Alignment.centerRight,
                            ),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                    if (_showGondolas)
                      ...espDevices.asMap().entries.map((entry) {
                        int index = entry.key;
                        DiscoveredDevice device = entry.value;
                        var position = beaconPositionsPixels[index % beaconPositionsPixels.length];
                        final distance = _getSmoothedDistance(device.id).toStringAsFixed(1);
                        return Positioned(
                          left: position['x']! - 12,
                          top: position['y']! - 36,
                          child: Column(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [Colors.blue.shade400, Colors.blue.shade800],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.blue.withOpacity(0.3),
                                      spreadRadius: 1,
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.router, color: Colors.white, size: 16),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade700,
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      spreadRadius: 1,
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  '$distance m',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    if (_showRouteDialog)
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _showRouteDialog = false;
                            });
                          },
                          child: Container(
                            color: Colors.black.withOpacity(0.02), // Semi-transparent overlay for dimming
                          ),
                        ),
                      ),
                    if (_showRouteDialog && _selectedProduct != null)
                      Positioned(
                        left: _selectedProduct!['name'] == 'Bebidas' ?
                        ((_selectedProduct!['x'] as double) / realWidthMeters * mapWidth - 220) :
                        ((_selectedProduct!['x'] as double) / realWidthMeters * mapWidth - 100),
                        top: _selectedProduct!['name'] == 'Bebidas' ?
                        ((_selectedProduct!['y'] as double) / realHeightMeters * mapHeight - 50) :
                        ((_selectedProduct!['y'] as double) / realHeightMeters * mapHeight + 20),
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                            width: 200,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _currentTargetPos != null &&
                                    _currentTargetPos!['x'] == _selectedProduct!['x'] &&
                                    _currentTargetPos!['y'] == _selectedProduct!['y']
                                    ? [Colors.red.shade600, Colors.red.shade800]
                                    : [Colors.green.shade600, Colors.green.shade800],
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.1),
                                              blurRadius: 6,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: Text(
                                            _selectedProduct!['emoji'] as String,
                                            style: TextStyle(fontSize: 22, color: Colors.blueGrey.shade700),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _selectedProduct!['name'] as String,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                            Text(
                                              'Sección: ${_selectedProduct!['category']}',
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(0.8),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w400,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: GestureDetector(
                                    onTap: _toggleRoute,
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.1),
                                            blurRadius: 6,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            _currentTargetPos != null &&
                                                _currentTargetPos!['x'] == _selectedProduct!['x'] &&
                                                _currentTargetPos!['y'] == _selectedProduct!['y']
                                                ? Icons.stop_rounded
                                                : Icons.navigation_rounded,
                                            color: _currentTargetPos != null &&
                                                _currentTargetPos!['x'] == _selectedProduct!['x'] &&
                                                _currentTargetPos!['y'] == _selectedProduct!['y']
                                                ? Colors.red.shade600
                                                : Colors.green.shade600,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _currentTargetPos != null &&
                                                _currentTargetPos!['x'] == _selectedProduct!['x'] &&
                                                _currentTargetPos!['y'] == _selectedProduct!['y']
                                                ? 'Detener'
                                                : 'Navegar',
                                            style: TextStyle(
                                              color: _currentTargetPos != null &&
                                                  _currentTargetPos!['x'] == _selectedProduct!['x'] &&
                                                  _currentTargetPos!['y'] == _selectedProduct!['y']
                                                  ? Colors.red.shade600
                                                  : Colors.green.shade600,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FloatingActionButton(
                        mini: true,
                        backgroundColor: _autoMode ? Colors.green : const Color(0xFF003DA5),
                        onPressed: _toggleAutoMode,
                        child: Icon(
                          Icons.directions_run,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_currentTargetPos != null && _selectedProduct != null)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF003DA5).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.location_on,
                            color: Color(0xFF003DA5),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            (_selectedProduct!['isGroup'] == true && _selectedProduct!['isCategory'] != true) ? 'Ubicación de la Sección' : 'Ubicación del Producto',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    AnimatedContainer(
                      duration: Duration(milliseconds: 500),
                      decoration: BoxDecoration(
                        border: _highlightDetails ? Border.all(color: Colors.blue, width: 2) : null,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          border: Border.all(
                            color: const Color(0xFF003DA5).withOpacity(0.1),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selectedProduct!['isCategory'] == true && _selectedProduct!['isGroup'] == true) ...[
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.eco,
                                      color: Colors.green,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _selectedProduct!['name'] as String,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1A1A1A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        'Categoría: ',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF57C00),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _selectedProduct!['category'] as String,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF57C00).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.category,
                                      size: 16,
                                      color: Color(0xFFF57C00),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.place,
                                        size: 16,
                                        color: Color(0xFF666666),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _selectedProduct!['location'] as String,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.store,
                                      size: 16,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_selectedProduct!['isGroup'] == true) ...[
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.eco,
                                      color: Colors.green,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _selectedProduct!['name'] as String,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1A1A1A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        'Categoría: ',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF57C00),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _selectedProduct!['category'] as String,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF57C00).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.category,
                                      size: 16,
                                      color: Color(0xFFF57C00),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.place,
                                        size: 16,
                                        color: Color(0xFF666666),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _selectedProduct!['location'] as String,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.store,
                                      size: 16,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Productos en esta sección:',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              ...(_selectedProduct!['subProducts'] as List<Map<String, dynamic>>).map((subProd) {
                                String name = subProd['name'] as String;
                                bool? status = _productStatus[name];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          name,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF1A1A1A),
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () {
                                          _onCheckChanged(name, status == true ? null : true);
                                        },
                                        child: Icon(
                                          Icons.check_circle,
                                          color: status == true ? Colors.green : Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      GestureDetector(
                                        onTap: () {
                                          _onCheckChanged(name, status == false ? null : false);
                                        },
                                        child: Icon(
                                          Icons.cancel,
                                          color: status == false ? Colors.red : Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ] else ...[
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.eco,
                                      color: Colors.green,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _selectedProduct!['name'] as String,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1A1A1A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        'Categoría: ',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF57C00),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _selectedProduct!['category'] as String,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF57C00).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.category,
                                      size: 16,
                                      color: Color(0xFFF57C00),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.place,
                                        size: 16,
                                        color: Color(0xFF666666),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _selectedProduct!['location'] as String,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF666666),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.store,
                                      size: 16,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Productos en esta sección:',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _selectedProduct!['name'] as String,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF1A1A1A),
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () {
                                        String name = _selectedProduct!['name'] as String;
                                        bool? status = _productStatus[name];
                                        _onCheckChanged(name, status == true ? null : true);
                                      },
                                      child: Icon(
                                        Icons.check_circle,
                                        color: _productStatus[_selectedProduct!['name']] == true ? Colors.green : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    GestureDetector(
                                      onTap: () {
                                        String name = _selectedProduct!['name'] as String;
                                        bool? status = _productStatus[name];
                                        _onCheckChanged(name, status == false ? null : false);
                                      },
                                      child: Icon(
                                        Icons.cancel,
                                        color: _productStatus[_selectedProduct!['name']] == false ? Colors.red : Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () {},
                                icon: const Icon(Icons.volume_up, size: 20),
                                label: const Text(
                                  'Escuchar indicaciones de voz',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF003DA5),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  elevation: 2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            const Text(
              'Cómo Utilizar el Mapa',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF424242),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Aprende a moverte por el supermercado con nuestras herramientas',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF757575),
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 100,
              child: PageView(
                controller: PageController(viewportFraction: 1.0),
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8.0),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF4CAF50), Color(0xFF66BB6A)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.route_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Text(
                                  'Ruta Óptima',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Sigue el camino verde para evitar obstáculos y encontrar la ruta más rápida hacia tu producto.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8.0),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF009688), Color(0xFF4DB6AC)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.teal.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.touch_app,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Text(
                                  'Navegación Interactiva',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Usa tus dedos para desplazarte por el mapa del supermercado. Puedes acercar para ver detalles de un pasillo o alejar para tener una vista completa.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8.0),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF9800), Color(0xFFFFB74D)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.orange.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.shopping_cart,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Text(
                                  'Ubicación de Productos',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Cada producto aparece marcado en su pasillo correspondiente. Solo tienes que seguir los indicadores para localizar lo que buscas.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8.0),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF3F51B5), Color(0xFF7986CB)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.indigo.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.settings,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Text(
                                  'Herramientas Adicionales',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Accede a funciones como búsqueda de productos, vista del recorrido completo y tu posición actual en el supermercado para mejorar tu experiencia de compra.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_showGondolas) ...[
              const SizedBox(height: 8),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _isScanning ? Colors.green.shade50 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isScanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
                          color: _isScanning ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isScanning ? 'Escaneando dispositivos...' : 'Escaneo detenido',
                          style: TextStyle(
                            color: _isScanning ? Colors.green : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (_isScanning)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    if (_isScanning)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Detectados: $_deviceCount | En lista: ${_devices.length}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dispositivos detectados: ${_devices.length}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    _hasPermissions
                        ? _devices.isEmpty
                        ? Center(
                      child: Column(
                        children: [
                          const Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey),
                          const SizedBox(height: 4),
                          Text(
                            _isScanning
                                ? 'Buscando dispositivos...\nAsegúrate de que tu beacon esté encendido'
                                : 'No se encontraron dispositivos\nReiniciando escaneo...',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                          if (!_isScanning && _deviceCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Se detectaron $_deviceCount dispositivos pero fueron filtrados por señal débil',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12, color: Colors.orange),
                              ),
                            ),
                        ],
                      ),
                    )
                        : SizedBox(
                      height: MediaQuery.of(context).size.height * 0.4,
                      child: ListView.builder(
                        shrinkWrap: true,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _devices.length,
                        itemBuilder: (context, index) {
                          final device = _devices[index];
                          final distance = _getSmoothedDistance(device.id);
                          final isEsp = _isEsp32(device);

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isEsp ? Colors.blue : Colors.grey,
                                child: Text(
                                  _getDeviceTypeIcon(device),
                                  style: const TextStyle(fontSize: 20),
                                ),
                              ),
                              title: Text(
                                device.name.isNotEmpty
                                    ? device.name
                                    : 'Dispositivo ${isEsp ? "" : "desconocido"}',
                                style: TextStyle(
                                  fontWeight: isEsp ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('MAC: ${device.id}'),
                                  Text('RSSI: ${device.rssi} dBm'),
                                  Text('Distancia: ${distance.toStringAsFixed(1)} m'),
                                  if (isEsp)
                                    const Text(
                                      'Beacon',
                                      style: TextStyle(
                                        color: Colors.blue,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                ],
                              ),
                              trailing: isEsp
                                  ? const Icon(Icons.verified, color: Colors.green)
                                  : null,
                            ),
                          );
                        },
                      ),
                    )
                        : Column(
                      children: [
                        const Icon(Icons.warning, size: 64, color: Colors.orange),
                        const SizedBox(height: 16),
                        const Text(
                          'Se requieren permisos de ubicación y Bluetooth',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _requestAllPermissions,
                          child: const Text('Solicitar Permisos'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: _showGondolas
          ? FloatingActionButton(
        onPressed: () {
          if (_isScanning) {
            _stopScan();
          } else {
            _startScan();
          }
        },
        tooltip: _isScanning ? 'Detener escaneo' : 'Comenzar escaneo',
        backgroundColor: _isScanning ? Colors.red : const Color(0xFF003DA5),
        child: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching, color: Colors.white),
      )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        items: <BottomNavigationBarItem>[
          const BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Inicio',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Lista',
          ),
          BottomNavigationBarItem(
            icon: Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFFD100),
              ),
              child: const Center(
                child: Text(
                  'S',
                  style: TextStyle(
                    fontSize: 32,
                    color: Color(0xFF003DA5),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            label: '',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.location_on),
            label: 'Mapa',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            label: 'Más',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFF003DA5),
        unselectedItemColor: Colors.grey,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        showSelectedLabels: true,
        showUnselectedLabels: true,
      ),
    );
  }
}