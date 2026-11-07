import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Color;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://fnlmdavyznvekyneywix.supabase.co',
);
const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_lddqezmCIuKITAh803PX-g_tl2DhFQm',
);

SupabaseClient get supabase => Supabase.instance.client;

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

Color _hex(String? h) {
  try {
    return Color(int.parse('FF${h!.substring(1)}', radix: 16));
  } catch (_) {
    return const Color(0xFFC62828);
  }
}

class RouteSummary {
  final int id;
  final String code;
  final String name;
  final Color color;
  RouteSummary(this.id, this.code, this.name, this.color);
  String get label => '$code · $name';
}

class StopItem {
  final int order;
  final String name;
  final LatLng pos;
  StopItem(this.order, this.name, this.pos);
}

class RouteDetail {
  final List<LatLng> line;
  final List<StopItem> stops;
  RouteDetail(this.line, this.stops);
}

class VehiclePos {
  final int vehicleId;
  final String code;
  final int routeId;
  final LatLng pos;
  VehiclePos(this.vehicleId, this.code, this.routeId, this.pos);

  /// อ่านจากแถวของตาราง vehicles
  /// คืน null ถ้ารถไม่พร้อมแสดง (ไม่มีพิกัด ไม่มีสาย หรือสถานะไม่ใช่ ACTIVE)
  static VehiclePos? tryParse(Map<String, dynamic> j) {
    final lat = j['latitude'];
    final lng = j['longitude'];
    final routeId = j['routeId'];
    if (lat is! num || lng is! num || routeId == null) return null;
    if (j['status'] != null && j['status'] != 'ACTIVE') return null;
    return VehiclePos(
      j['id'] as int,
      (j['code'] ?? '') as String,
      routeId as int,
      LatLng(lat.toDouble(), lng.toDouble()),
    );
  }
}

Future<List<RouteSummary>> fetchRoutes() async {
  try {
    final rows = await supabase
        .from('routes')
        .select('id, code, name, color')
        .eq('isActive', true)
        .order('id', ascending: true); // order() เรียงจากมากไปน้อยเป็นค่าเริ่มต้น
    return rows
        .map(
          (r) => RouteSummary(r['id'], r['code'], r['name'], _hex(r['color'])),
        )
        .toList();
  } catch (e) {
    throw ApiException('โหลดข้อมูลไม่ได้: $e');
  }
}

// แปลงเส้นทางได้ทั้ง GeoJSON (FeatureCollection / Feature / LineString)
// และอาร์เรย์ธรรมดา [[lng,lat], ...]  (พิกัดเรียง lng, lat ตามมาตรฐาน GeoJSON)
List<LatLng> _parseLine(dynamic data) {
  final out = <LatLng>[];

  void addCoords(dynamic coords) {
    if (coords is! List) return;
    if (coords.length >= 2 && coords[0] is num && coords[1] is num) {
      out.add(
        LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble()),
      );
      return;
    }
    for (final c in coords) {
      addCoords(c);
    }
  }

  void walk(dynamic d) {
    if (d is List) {
      addCoords(d);
    } else if (d is Map) {
      switch (d['type']) {
        case 'FeatureCollection':
          for (final f in (d['features'] as List? ?? [])) {
            walk(f);
          }
        case 'Feature':
          walk(d['geometry']);
        case 'LineString' || 'MultiLineString':
          addCoords(d['coordinates']);
      }
    }
  }

  walk(data);
  return out;
}

// อ่านป้ายจากตาราง stops ตรง ๆ (ไม่ต้องพึ่ง route_stops / foreign key)
// เรียงตามรหัสป้าย (P01 -> P14) ในโค้ดเอง ไม่พึ่งการเรียงของฐานข้อมูล
Future<RouteDetail> fetchRoute(int id) async {
  try {
    final route = await supabase
        .from('routes')
        .select('geometry, path_coordinates')
        .eq('id', id)
        .single();

    final rows = await supabase
        .from('stops')
        .select('code, name, latitude, longitude')
        .eq('isActive', true);

    int numOf(dynamic code) =>
        int.tryParse('$code'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 9999;

    final sorted = List<Map<String, dynamic>>.from(rows)
      ..sort((a, b) => numOf(a['code']).compareTo(numOf(b['code'])));

    final stops = <StopItem>[
      for (var i = 0; i < sorted.length; i++)
        StopItem(
          i + 1,
          sorted[i]['name'] as String,
          LatLng(
            (sorted[i]['latitude'] as num).toDouble(),
            (sorted[i]['longitude'] as num).toDouble(),
          ),
        ),
    ];

    debugPrint('stops=${stops.map((s) => '${s.order}:${s.name}').toList()}');

    // เส้นที่เพื่อนวาด (path_coordinates) > geometry > ต่อเส้นจากป้าย
    var line = _parseLine(route['path_coordinates']);
    if (line.length < 2) line = _parseLine(route['geometry']);
    if (line.length < 2) line = stops.map((s) => s.pos).toList();

    return RouteDetail(line, stops);
  } catch (e) {
    throw ApiException('โหลดข้อมูลไม่ได้: $e');
  }
}