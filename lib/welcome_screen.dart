import 'package:flutter/material.dart';
import 'home_screen.dart';

const _yellow = Color(0xFFF4B942);
const _ink = Color(0xFF111111);

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  void _start(BuildContext context) {
    // pushReplacement = กดย้อนกลับจากหน้าแผนที่แล้วจะไม่กลับมาหน้านี้
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // พื้นหลัง: ฟ้า เมฆ เนินเขา ถนน และรถบัสการ์ตูน
          const CustomPaint(painter: _WelcomePainter()),

          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 36),
                const Text(
                  'Shutter Bus',
                  style: TextStyle(
                    fontSize: 46,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Color(0x55000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'ติดตามรถรับส่งในมหาวิทยาลัยรังสิต',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Color(0x55000000),
                        blurRadius: 6,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),

                // ปุ่ม Start กลางจอ
                Expanded(
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(40),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 18,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        width: 220,
                        height: 62,
                        child: FilledButton(
                          onPressed: () => _start(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: _yellow,
                            foregroundColor: _ink,
                            shape: const StadiumBorder(),
                          ),
                          child: const Text(
                            'Start',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // เว้นที่ด้านล่างให้เห็นรถบัสบนถนน
                SizedBox(height: MediaQuery.of(context).size.height * 0.26),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// วาดฉากการ์ตูน: ฟ้า ดวงอาทิตย์ เมฆ เนินเขา ถนน และรถบัสสีเหลือง
class _WelcomePainter extends CustomPainter {
  const _WelcomePainter();

  void _cloud(Canvas c, double cx, double cy, double s) {
    final p = Paint()..color = Colors.white.withAlpha(235);
    c.drawCircle(Offset(cx, cy), 18 * s, p);
    c.drawCircle(Offset(cx + 20 * s, cy - 10 * s), 22 * s, p);
    c.drawCircle(Offset(cx + 44 * s, cy), 18 * s, p);
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - 18 * s, cy - 2 * s, 80 * s, 20 * s),
        Radius.circular(10 * s),
      ),
      p,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ท้องฟ้า
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6EB9EE), Color(0xFFCDEBFF)],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // ดวงอาทิตย์
    canvas.drawCircle(
      Offset(w * 0.84, h * 0.2),
      34,
      Paint()..color = const Color(0xFFFFE08A),
    );

    // เมฆ
    _cloud(canvas, w * 0.08, h * 0.30, 1.0);
    _cloud(canvas, w * 0.62, h * 0.38, 0.8);

    // เนินเขา 2 ชั้น
    final roadTop = h * 0.80;
    canvas.drawPath(
      Path()
        ..moveTo(0, roadTop)
        ..quadraticBezierTo(w * 0.25, roadTop - 110, w * 0.55, roadTop - 30)
        ..quadraticBezierTo(w * 0.8, roadTop + 10, w, roadTop - 70)
        ..lineTo(w, roadTop)
        ..close(),
      Paint()..color = const Color(0xFF9AD08B),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, roadTop)
        ..quadraticBezierTo(w * 0.3, roadTop - 50, w * 0.6, roadTop - 10)
        ..quadraticBezierTo(w * 0.85, roadTop + 10, w, roadTop - 30)
        ..lineTo(w, roadTop)
        ..close(),
      Paint()..color = const Color(0xFF6FBF73),
    );

    // ถนน
    canvas.drawRect(
      Rect.fromLTWH(0, roadTop, w, h - roadTop),
      Paint()..color = const Color(0xFF4B5563),
    );
    final dash = Paint()..color = Colors.white.withAlpha(220);
    final dashY = roadTop + (h - roadTop) * 0.62;
    for (double x = 10; x < w; x += 56) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, dashY, 32, 6),
          const Radius.circular(3),
        ),
        dash,
      );
    }

    // ───── รถบัสการ์ตูน (หันหน้าไปทางขวา) ─────
    final bw = (w * 0.86).clamp(240.0, 380.0);
    final bh = bw * 0.44;
    final left = (w - bw) / 2;
    final top = roadTop - bh * 0.80;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, bw, bh),
      const Radius.circular(22),
    );

    // เงาใต้รถ
    canvas.drawOval(
      Rect.fromLTWH(left + 8, top + bh - 6, bw - 16, 16),
      Paint()..color = Colors.black.withAlpha(70),
    );

    // ตัวถัง + แถบหลังคา
    canvas.drawRRect(body, Paint()..color = _yellow);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, bw, bh * 0.12),
        topLeft: const Radius.circular(22),
        topRight: const Radius.circular(22),
      ),
      Paint()..color = const Color(0xFFE2A02B),
    );

    // แถบดำข้างตัวถัง
    canvas.drawRect(
      Rect.fromLTWH(left, top + bh * 0.66, bw, bh * 0.07),
      Paint()..color = const Color(0xFF2A2A2A),
    );

    // หน้าต่างด้านข้าง
    final win = Paint()..color = const Color(0xFFBFE6FF);
    final winEdge = Paint()
      ..color = const Color(0xFF2A2A2A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final winW = bw * 0.15;
    final winH = bh * 0.30;
    final winTop = top + bh * 0.22;
    for (var i = 0; i < 4; i++) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(left + bw * 0.07 + i * (winW + bw * 0.035), winTop, winW, winH),
        const Radius.circular(8),
      );
      canvas.drawRRect(r, win);
      canvas.drawRRect(r, winEdge);
    }

    // กระจกหน้า (ด้านขวา) มีหน้ายิ้ม
    final front = RRect.fromRectAndRadius(
      Rect.fromLTWH(left + bw * 0.80, winTop, bw * 0.15, winH * 1.25),
      const Radius.circular(10),
    );
    canvas.drawRRect(front, win);
    canvas.drawRRect(front, winEdge);
    final eye = Paint()..color = const Color(0xFF2A2A2A);
    final fx = left + bw * 0.80 + bw * 0.075;
    canvas.drawCircle(Offset(fx - 7, winTop + winH * 0.45), 3.2, eye);
    canvas.drawCircle(Offset(fx + 7, winTop + winH * 0.45), 3.2, eye);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(fx, winTop + winH * 0.62),
        width: 18,
        height: 12,
      ),
      0.15,
      2.85,
      false,
      Paint()
        ..color = const Color(0xFF2A2A2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // ไฟหน้า + กันชน
    canvas.drawCircle(
      Offset(left + bw - 8, top + bh * 0.68),
      7,
      Paint()..color = const Color(0xFFFFF3B0),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + bw * 0.86, top + bh * 0.86, bw * 0.15, bh * 0.09),
        const Radius.circular(5),
      ),
      Paint()..color = const Color(0xFF2A2A2A),
    );

    // ล้อ
    for (final cx in [left + bw * 0.22, left + bw * 0.74]) {
      final c = Offset(cx, top + bh);
      canvas.drawCircle(c, bh * 0.19, Paint()..color = const Color(0xFF1F1F1F));
      canvas.drawCircle(c, bh * 0.09, Paint()..color = const Color(0xFFB8BEC6));
    }
  }

  @override
  bool shouldRepaint(covariant _WelcomePainter old) => false;
}