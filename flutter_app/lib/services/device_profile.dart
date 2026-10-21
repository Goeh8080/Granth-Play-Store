import 'native_bridge.dart';

/// How much work the phone can take while making PDFs.
///
/// Low-RAM phones (Android Go, 1–2 GB) make one PDF at a time with fewer pictures in
/// memory; ordinary phones make up to three at once.
class DeviceProfile {
  DeviceProfile({this.sdk = 0, this.lowRam = false, this.memClassMb = 256});

  static DeviceProfile I = DeviceProfile();

  final int sdk;
  final bool lowRam;

  /// Java heap class in MB — a good proxy for how much RAM the app may use overall.
  final int memClassMb;

  bool get small => lowRam || memClassMb <= 128;
  bool get medium => !small && memClassMb <= 192;

  /// PDFs built at the same time.
  int get pdfSlots => small ? 1 : (medium ? 2 : 3);

  /// Pictures prepared ahead of the page being drawn.
  int get pdfLookAhead => small ? 3 : (medium ? 5 : 8);

  /// Memory for original-size page pictures waiting to be written into the PDF.
  int get pdfHeldBytes => (small ? 20 : (medium ? 40 : 64)) << 20;

  /// Parallel picture downloads per PDF.
  int get imageWorkers => small ? 3 : (medium ? 5 : 8);

  static Future<void> load() async {
    final m = await NativeBridge.deviceInfo();
    if (m == null) return;
    int n(Object? v, int d) => v is num ? v.toInt() : d;
    I = DeviceProfile(sdk: n(m['sdk'], 0), lowRam: m['lowRam'] == true, memClassMb: n(m['memClassMb'], 256));
  }
}
