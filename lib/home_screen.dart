import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'api.dart';

const _ink = Color(0xFF12212B);
const _muted = Color(0xFF4A5864);
const _green = Color(0xFF2E9E5B);

// ดึงเลขตึกจากชื่อป้าย เช่น "ตึก 11" -> "11" (ถ้าไม่มีตัวเลข ใช้เลขลำดับแทน)
String _buildingNo(String name, int fallback) =>
    RegExp(r'\d+').firstMatch(name)?.group(0) ?? '$fallback';

String _two(int n) => n.toString().padLeft(2, '0');
String _hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// สายรถที่อ่านจากตาราง routes ตรง ๆ (ไม่ผ่าน fetchRoutes)
class _RouteItem {
  final int id;
  final String code;
  final String name;
  final Color color;
  const _RouteItem(this.id, this.code, this.name, this.color);

  String get label => '$code · $name';

  factory _RouteItem.fromJson(Map<String, dynamic> j) {
    final hex = ((j['color'] as String?) ?? '#C62828').replaceAll('#', '');
    return _RouteItem(
      j['id'] as int,
      (j['code'] ?? '') as String,
      (j['name'] ?? '') as String,
      Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFC62828),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _map = MapController();
  final _sheet = DraggableScrollableController(); // ควบคุมแผงด้านล่าง
  RealtimeChannel? _channel;
  List<_RouteItem> _routes = [];
  _RouteItem? _selected;
  RouteDetail? _detail;
  final Map<int, VehiclePos> _vehicles = {};
  bool _loading = true;
  String? _error;
  int? _focusedVehicleId; // รถที่กำลังซูมดูอยู่
  int? _focusedStopOrder; // ป้ายที่กดซูมดูอยู่
  DateTime? _lastUpdate; // เวลาที่รับข้อมูลรถล่าสุด
  LatLng? _me; // ตำแหน่งของผู้ใช้ (เก็บในเครื่อง ไม่ส่งไปที่ไหน)
  bool _locating = false;
  bool _meFocused = false; // กำลังซูมดูตำแหน่งของผู้ใช้อยู่

  @override
  void initState() {
    super.initState();
    _connectRealtime();
    _loadRoutes();
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  // ถ้าสายไม่มีเส้นใน geometry ให้ต่อเส้นจากป้ายตามลำดับแทน
  List<LatLng> _lineOf(RouteDetail d) =>
      d.line.length >= 2 ? d.line : d.stops.map((s) => s.pos).toList();

  // ซูมให้เห็นทั้งเส้นทางของสายที่เลือก (หน้าหลัก)
  void _fitRoute() {
    final d = _detail;
    if (d == null) return;
    final pts = _lineOf(d);
    if (pts.length < 2) return;
    try {
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(40, 120, 40, 260),
        ),
      );
    } catch (e) {
      debugPrint('fitCamera error: $e');
    }
  }

  // กดรถครั้งแรก = ซูมไปที่รถ, กดซ้ำคันเดิม = กลับมาหน้าหลัก
  void _toggleVehicle(VehiclePos v) {
    if (_focusedVehicleId == v.vehicleId) {
      _set(() => _focusedVehicleId = null);
      _fitRoute();
    } else {
      _set(() {
        _focusedVehicleId = v.vehicleId;
        _focusedStopOrder = null;
        _meFocused = false;
      });
      _map.move(v.pos, 16);
    }
  }

  // เลื่อนแผนที่ไปที่ p โดยให้จุดอยู่กลางส่วนที่ไม่ถูกแผงบัง
  void _moveShifted(LatLng p, double zoom) {
    final shiftPx = MediaQuery.of(context).size.height * 0.15;
    final metersPerPx =
        156543.03392 * math.cos(p.latitudeInRad) / math.pow(2, zoom);
    final dLat = shiftPx * metersPerPx / 111320;
    _map.move(LatLng(p.latitude - dLat, p.longitude), zoom);
  }

  // กดป้ายในรายการ: ซูมเข้าที่ป้าย / กดป้ายเดิมซ้ำ = ซูมออกกลับมาเห็นทั้งเส้นทาง
  void _focusStop(StopItem s) {
    if (_focusedStopOrder == s.order) {
      _set(() => _focusedStopOrder = null);
      _fitRoute();
      return;
    }

    _set(() {
      _focusedStopOrder = s.order;
      _focusedVehicleId = null;
      _meFocused = false;
    });
    if (_sheet.isAttached && _sheet.size > 0.35) {
      _sheet.animateTo(
        0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    _moveShifted(s.pos, 18);
  }

  // ป้ายที่อยู่ใกล้ตำแหน่ง p ที่สุดในสายที่เลือก (พร้อมระยะเป็นเมตร)
  ({String name, double meters})? _nearestStop(LatLng p) {
    final stops = _detail?.stops;
    if (stops == null || stops.isEmpty) return null;
    const d = Distance();
    var best = stops.first;
    var bd = double.infinity;
    for (final s in stops) {
      final m = d(p, s.pos);
      if (m < bd) {
        bd = m;
        best = s;
      }
    }
    return (name: best.name, meters: bd);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ปุ่ม "ตำแหน่งฉัน": กดครั้งแรก = ขออนุญาต -> หาตำแหน่ง -> ซูม -> บอกป้ายใกล้ที่สุด
  // กดซ้ำ = กลับมาเห็นทั้งเส้นทาง
  Future<void> _locateMe() async {
    // กดซ้ำตอนกำลังซูมดูตำแหน่งตัวเอง -> กลับมาเห็นทั้งเส้นทาง
    if (_meFocused) {
      _set(() {
        _meFocused = false;
        _me = null;
      });
      _fitRoute();
      return;
    }

    if (_locating) return;
    _set(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('กรุณาเปิดตำแหน่ง (GPS) ของเครื่อง');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        _toast('ไม่ได้รับอนุญาตให้ใช้ตำแหน่ง');
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        _toast('ปิดการใช้ตำแหน่งไว้ ไปเปิดได้ที่การตั้งค่าของเครื่อง');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final me = LatLng(pos.latitude, pos.longitude);
      _set(() {
        _me = me;
        _focusedVehicleId = null;
        _focusedStopOrder = null;
      });

      final near = _nearestStop(me);
      if (near != null && near.meters > 5000) {
        // อยู่ไกลจากเส้นทางมาก ไม่ย้ายแผนที่หนี แต่ให้รู้ว่าอยู่ไกล
        _toast(
          'คุณอยู่ห่างจากเส้นทางประมาณ ${(near.meters / 1000).toStringAsFixed(1)} กม.',
        );
        return;
      }
      _moveShifted(me, 17);
      _set(() => _meFocused = true);
      if (near != null) {
        _toast(
          'ป้ายใกล้คุณที่สุด: ${near.name} (ประมาณ ${near.meters.round()} ม.)',
        );
      }
    } catch (e) {
      debugPrint('locate error: $e');
      _toast('หาตำแหน่งไม่ได้ ลองใหม่อีกครั้ง');
    } finally {
      _set(() => _locating = false);
    }
  }

  // อ่านตำแหน่งรถจากตาราง vehicles
  Future<void> _connectRealtime() async {
    // ตำแหน่งรถตอนเปิดแอป
    try {
      final rows = await supabase
          .from('vehicles')
          .select('id, code, routeId, status, latitude, longitude');
      _set(() {
        _vehicles.clear();
        for (final e in rows) {
          final v = VehiclePos.tryParse(Map<String, dynamic>.from(e));
          if (v != null) _vehicles[v.vehicleId] = v;
        }
        _lastUpdate = DateTime.now();
      });
    } catch (e) {
      debugPrint('vehicles load error: $e');
    }

    // ฟังการเปลี่ยนแปลงแบบเรียลไทม์
    _channel = supabase
        .channel('vehicles')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'vehicles',
          callback: (payload) {
            if (payload.eventType == PostgresChangeEvent.delete) {
              final id = payload.oldRecord['id'];
              _set(() {
                _vehicles.remove(id);
                _lastUpdate = DateTime.now();
              });
              return;
            }
            final rec = Map<String, dynamic>.from(payload.newRecord);
            final v = VehiclePos.tryParse(rec);
            _set(() {
              if (v != null) {
                _vehicles[v.vehicleId] = v;
              } else {
                _vehicles.remove(rec['id']); // เช่น เปลี่ยนเป็น MAINTENANCE
              }
              _lastUpdate = DateTime.now();
            });
          },
        )
        .subscribe();
  }

  Future<void> _loadRoutes() async {
    _set(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await supabase
          .from('routes')
          .select('id, code, name, color')
          .eq('isActive', true)
          .order('id', ascending: true); // order() เรียงจากมากไปน้อยเป็นค่าเริ่มต้น
      final routes = rows
          .map((e) => _RouteItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      debugPrint('routes=${routes.map((r) => '${r.id}:${r.label}').toList()}');
      _set(() => _routes = routes);
      if (routes.isNotEmpty) {
        // จำสายที่เลือกอยู่ ถ้าไม่มีแล้วค่อยใช้สายแรก
        final keep = routes.firstWhere(
          (r) => r.id == _selected?.id,
          orElse: () => routes.first,
        );
        await _select(keep);
      }
    } catch (e) {
      debugPrint('loadRoutes error: $e');
      _set(() => _error = 'โหลดรายการสายไม่ได้: $e');
    } finally {
      _set(() => _loading = false);
    }
  }

  Future<void> _select(_RouteItem r) async {
    _set(() {
      _selected = r;
      _detail = null;
      _error = null;
      _focusedVehicleId = null;
      _focusedStopOrder = null;
      _meFocused = false;
    });
    try {
      final d = await fetchRoute(r.id);
      final pts = _lineOf(d);
      debugPrint(
        'select ${r.id}: line=${d.line.length} stops=${d.stops.length} '
        'first=${pts.isNotEmpty ? pts.first : null}',
      );
      if (!mounted || _selected?.id != r.id) return;
      setState(() => _detail = d);
      if (pts.length >= 2) {
        _fitRoute();
      } else {
        _set(() => _error = 'สายนี้ยังไม่มีป้ายหรือเส้นทางในฐานข้อมูล');
      }
    } on ApiException catch (e) {
      _set(() => _error = e.message);
    } catch (e) {
      debugPrint('select error: $e');
      _set(() => _error = 'โหลดสายนี้ไม่ได้: $e');
    }
  }

  @override
  void dispose() {
    if (_channel != null) supabase.removeChannel(_channel!);
    _sheet.dispose();
    _map.dispose();
    super.dispose();
  }

  // ───── ชิปเลือกสาย: ลอยบนแผนที่ ไม่มีแถบสีขาวครอบ ไม่มีปุ่มรีเฟรช ─────
  Widget _routeChips() {
    if (_routes.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Material(
          elevation: 3,
          color: Colors.white,
          shape: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              _loading ? 'กำลังโหลดสายรถ…' : 'ไม่พบสายรถ',
              style: const TextStyle(color: _muted),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none, // ไม่ตัดเงาของชิป
        itemCount: _routes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final r = _routes[i];
          final sel = r.id == _selected?.id;
          return Material(
            elevation: 3,
            color: sel ? r.color : Colors.white,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: sel ? null : () => _select(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sel)
                      const Icon(
                        Icons.directions_bus_rounded,
                        size: 18,
                        color: Colors.white,
                      )
                    else
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: r.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      r.code,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: sel ? Colors.white : _ink,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      r.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: sel ? Colors.white : _muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ───── แถบสถานะรถ: จำนวนรถที่กำลังวิ่ง + รถแต่ละคันอยู่ใกล้ป้ายไหน ─────
  Widget _statusSection(List<VehiclePos> onRoute) {
    final running = onRoute.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: running ? _green : const Color(0xFF9AA3AB),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                running
                    ? 'รถกำลังวิ่ง ${onRoute.length} คัน'
                    : 'ขณะนี้ไม่มีรถให้บริการในสายนี้',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
            ),
            if (_lastUpdate != null)
              Text(
                'อัปเดต ${_hms(_lastUpdate!)}',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
          ],
        ),
        if (running) ...[
          const SizedBox(height: 10),
          for (final v in onRoute)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _VehicleStatusCard(
                code: v.code,
                subtitle: _vehicleSubtitle(v),
                focused: _focusedVehicleId == v.vehicleId,
                onTap: () => _toggleVehicle(v),
              ),
            ),
        ],
      ],
    );
  }

  String _vehicleSubtitle(VehiclePos v) {
    final near = _nearestStop(v.pos);
    if (near == null) return 'กำลังคำนวณตำแหน่ง…';
    if (near.meters > 800) return 'อยู่นอกพื้นที่เส้นทาง';
    return 'ใกล้ ${near.name} (ประมาณ ${near.meters.round()} ม.)';
  }

  @override
  Widget build(BuildContext context) {
    final color = _selected?.color ?? const Color(0xFFC62828);
    final onRoute = _vehicles.values
        .where((v) => v.routeId == _selected?.id)
        .toList();
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(13.9655, 100.5860), // ม.รังสิต (ค่าโดยประมาณ)
              initialZoom: 16,
              minZoom: 10,
              maxZoom: 19,
              // เปิดกลับได้เมื่อทดสอบเสร็จ
              // cameraConstraint: CameraConstraint.contain(
              //   bounds: LatLngBounds(
              //     const LatLng(13.955, 100.575),
              //     const LatLng(13.975, 100.597),
              //   ),
              // ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.tram_passenger',
              ),
              if (_detail != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _lineOf(_detail!),
                      strokeWidth: 5,
                      color: color,
                    ),
                  ],
                ),

              // ───── ป้ายบนแผนที่: จุดแดงมีเลขตึก (ป้ายที่เลือกใหญ่ ขอบเหลือง และอยู่บนสุด) ─────
              if (_detail != null)
                MarkerLayer(
                  markers: [
                    for (final s in [
                      ..._detail!.stops.where(
                        (e) => e.order != _focusedStopOrder,
                      ),
                      ..._detail!.stops.where(
                        (e) => e.order == _focusedStopOrder,
                      ),
                    ])
                      Marker(
                        point: s.pos,
                        width: s.order == _focusedStopOrder ? 40 : 28,
                        height: s.order == _focusedStopOrder ? 40 : 28,
                        child: _StopDot(
                          label: _buildingNo(s.name, s.order),
                          color: color,
                          focused: s.order == _focusedStopOrder,
                        ),
                      ),
                  ],
                ),

              // ───── รถ: ไอคอนรถบัส กดแล้วซูมไปที่รถ / กดซ้ำเพื่อกลับ ─────
              MarkerLayer(
                markers: [
                  for (final v in onRoute)
                    Marker(
                      point: v.pos,
                      width: 90,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => _toggleVehicle(v),
                        child: _VehicleMarker(
                          code: v.code,
                          focused: _focusedVehicleId == v.vehicleId,
                        ),
                      ),
                    ),
                ],
              ),

              // ───── ตำแหน่งของผู้ใช้ (จุดสีน้ำเงิน) ─────
              if (_me != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _me!,
                      width: 48,
                      height: 48,
                      child: const _MeDot(),
                    ),
                  ],
                ),
            ],
          ),

          // ───── ชิปเลือกสายด้านบน ─────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _routeChips(),
            ),
          ),

          // ───── แผงด้านล่าง: ลากขึ้นได้ถึง 92% ดีดไปหยุดที่ 30% / 60% / 92% ─────
          DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: 0.3,
            minChildSize: 0.12,
            maxChildSize: 0.92,
            snap: true,
            snapSizes: const [0.3, 0.6, 0.92],
            builder: (context, scroll) => Material(
              elevation: 8,
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  // แถบจับ: กดเพื่อสลับระหว่างย่อ (30%) กับขยาย (92%)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _sheet.animateTo(
                      _sheet.size < 0.6 ? 0.92 : 0.3,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    ),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.fromLTRB(0, 4, 0, 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD9DEE3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFB3261E),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _loadRoutes,
                      child: const Text('ลองใหม่'),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ───── แถบสถานะรถ ─────
                  _statusSection(onRoute),

                  const SizedBox(height: 18),
                  const Text(
                    'ป้ายตามลำดับ',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),

                  // ───── รายการป้าย: กดซูมเข้าที่ป้าย กดซ้ำซูมออก + ลูกศรชี้ลงเชื่อมลำดับ ─────
                  if (_detail != null)
                    for (var i = 0; i < _detail!.stops.length; i++)
                      _StopTimelineRow(
                        order: _detail!.stops[i].order,
                        name: _detail!.stops[i].name,
                        color: color,
                        isLast: i == _detail!.stops.length - 1,
                        selected: _detail!.stops[i].order == _focusedStopOrder,
                        onTap: () => _focusStop(_detail!.stops[i]),
                      )
                  else if (_error == null)
                    // โครงการ์ดระหว่างรอโหลด
                    for (var i = 0; i < 3; i++) const _SkeletonCard(),
                ],
              ),
            ),
          ),

          // ───── ปุ่มตำแหน่งฉัน: ลอยเหนือแผงด้านล่าง เลื่อนตามเมื่อลากแผง ─────
          ListenableBuilder(
            listenable: _sheet,
            builder: (ctx, _) {
              final h = MediaQuery.of(ctx).size.height;
              final f = _sheet.isAttached ? _sheet.size : 0.3;
              return Positioned(
                right: 14,
                bottom: (h * f + 14).clamp(0.0, h * 0.62),
                child: _LocateButton(
                  busy: _locating,
                  active: _meFocused,
                  onTap: _locateMe,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// ปุ่มกลมสีขาว "ตำแหน่งฉัน"
class _LocateButton extends StatelessWidget {
  final bool busy;
  final bool active;
  final VoidCallback onTap;
  const _LocateButton({
    required this.busy,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    elevation: 4,
    color: Colors.white,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.6),
                )
              : Icon(
                  Icons.my_location_rounded,
                  size: 26,
                  color: active ? const Color(0xFF1E73E8) : _ink,
                ),
        ),
      ),
    ),
  );
}

/// จุดสีน้ำเงินแสดงตำแหน่งผู้ใช้ (มีวงเรืองรอบ ๆ)
class _MeDot extends StatelessWidget {
  const _MeDot();

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: Color(0x331E73E8),
          shape: BoxShape.circle,
        ),
      ),
      Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: const Color(0xFF1E73E8),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
        ),
      ),
    ],
  );
}

/// การ์ดสถานะรถหนึ่งคัน: ไอคอนรถ + รหัส + อยู่ใกล้ป้ายไหน
class _VehicleStatusCard extends StatelessWidget {
  final String code;
  final String subtitle;
  final bool focused;
  final VoidCallback onTap;
  const _VehicleStatusCard({
    required this.code,
    required this.subtitle,
    required this.focused,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: focused ? const Color(0xFFFFF8E1) : const Color(0xFFFAFBFC),
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: focused ? Colors.amber : const Color(0xFFE8ECF0),
            width: focused ? 1.8 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: _ink,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.directions_bus_rounded,
                size: 22,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    code,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _muted),
                  ),
                ],
              ),
            ),
            Icon(
              focused ? Icons.zoom_out_map_rounded : Icons.my_location_rounded,
              size: 22,
              color: focused ? Colors.amber.shade800 : const Color(0xFFB4BDC6),
            ),
          ],
        ),
      ),
    ),
  );
}

/// โครงการ์ดสีเทาจาง ๆ แสดงระหว่างรอโหลดรายการป้าย
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) => Container(
    height: 56,
    margin: const EdgeInsets.only(bottom: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFF1F4F7),
      borderRadius: BorderRadius.circular(16),
    ),
  );
}

/// จุดแดงมีเลข (ใช้บนแผนที่) ถ้า focused จะใหญ่ขึ้นและมีขอบสีเหลือง
class _StopDot extends StatelessWidget {
  final String label;
  final Color color;
  final bool focused;
  const _StopDot({
    required this.label,
    required this.color,
    this.focused = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: focused ? 38 : 28,
    height: focused ? 38 : 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(
        color: focused ? Colors.amber : Colors.white,
        width: focused ? 3.5 : 2,
      ),
      boxShadow: focused
          ? const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ]
          : null,
    ),
    child: Text(
      label,
      style: TextStyle(
        color: Colors.white,
        fontSize: focused ? 14 : 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// การ์ดป้ายในรายการ (โทนสบายตา): ป้ายเลขลำดับสีของสาย + ชื่อ + ลูกศรชี้ลงเชื่อมป้ายถัดไป
class _StopTimelineRow extends StatelessWidget {
  final int order;
  final String name;
  final Color color;
  final bool isLast;
  final bool selected;
  final VoidCallback onTap;
  const _StopTimelineRow({
    required this.order,
    required this.name,
    required this.color,
    required this.isLast,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: selected ? color.withAlpha(18) : const Color(0xFFFAFBFC),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? color : const Color(0xFFE8ECF0),
                  width: selected ? 1.5 : 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0A000000), // เงาบางมาก
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$order',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _ink,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: Color(0xFFB4BDC6),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ลูกศรชี้ลงเชื่อมไปการ์ดถัดไป (กึ่งกลาง สีเดียวกับป้ายเลข)
        if (!isLast)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Center(
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: color,
              ),
            ),
          )
        else
          const SizedBox(height: 6),
      ],
    );
  }
}

/// ไอคอนรถบนแผนที่ (วงกลม + ไอคอนรถบัส + ป้ายรหัสรถเล็ก ๆ ด้านล่าง)
class _VehicleMarker extends StatelessWidget {
  final String code;
  final bool focused;
  const _VehicleMarker({required this.code, required this.focused});

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    clipBehavior: Clip.none,
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: focused ? Colors.amber : _ink,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          Icons.directions_bus,
          size: 22,
          color: focused ? _ink : Colors.white,
        ),
      ),
      Positioned(
        top: 44,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Color(0x33000000), blurRadius: 3),
            ],
          ),
          child: Text(
            code,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
        ),
      ),
    ],
  );
}