import 'package:supabase_flutter/supabase_flutter.dart';
import 'api.dart';

Future<void> login(String email, String password) async {
  try {
    await supabase.auth.signInWithPassword(email: email, password: password);
  } on AuthException catch (e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login') || m.contains('invalid credentials')) {
      throw ApiException('อีเมลหรือรหัสผ่านไม่ถูกต้อง');
    }
    throw ApiException('เข้าสู่ระบบไม่สำเร็จ: ${e.message}');
  } catch (e) {
    throw ApiException('เชื่อมต่อ Supabase ไม่ได้: $e');
  }
}