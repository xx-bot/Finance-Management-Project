import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/sample_data.dart';
import '../../models/receipt_draft.dart';
import '../../services/photo_picker.dart';
import '../../services/receipt_service.dart';
import '../../state/ledger_state.dart';
import '../components/common.dart';
import '../theme.dart';
import 'review_screen.dart';
import 'connection_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.state, required this.service, required this.picker});
  final LedgerState state;
  final ReceiptService service;
  final ReceiptPhotoPicker picker;
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  ReceiptPhoto? _photo;
  bool _busy = false;
  bool _sampleBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recover();
  }

  Future<void> _recover() async {
    try {
      final photo = await widget.picker.recover();
      if (mounted && photo != null) setState(() => _photo = photo);
    } on Object { /* Camera cancellation and process recovery can be retried normally. */ }
  }

  Future<void> _pick(ImageSource source) async {
    setState(() => _error = null);
    try {
      final photo = await widget.picker.pick(source);
      if (mounted && photo != null) setState(() => _photo = photo);
    } on Object {
      if (mounted) setState(() => _error = 'We could not open the camera or photo library. Check the app’s permissions and try again.');
    }
  }

  Future<void> _review(ReceiptDraft draft) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ReviewScreen(state: widget.state, draft: draft)));
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _extract() async {
    if (_photo == null || _busy) return;
    if (!widget.service.isConfigured) {
      final connected = await _connect();
      if (!connected || !mounted) return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final draft = await widget.service.extract(_photo!, widget.state.currency);
      if (mounted) await _review(draft);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error is ReceiptServiceException ? error.message : 'Something went wrong while reading this receipt. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _connect() async {
    final service = widget.service;
    if (service is! ConnectableReceiptService) return false;
    final connected = await Navigator.push<bool>(context, MaterialPageRoute(
      builder: (_) => ConnectionScreen(service: service)));
    if (mounted) setState(() => _error = null);
    return connected == true && service.isConfigured;
  }

  Future<void> _sample() async {
    setState(() { _sampleBusy = true; _error = null; });
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    setState(() => _sampleBusy = false);
    await _review(sampleReceipt());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a receipt'), centerTitle: true),
      body: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 26), children: [
        Text(_photo == null ? 'Every receipt tells\na little story.' : 'A clear photo.\nA clearer picture.', style: theme.headlineMedium),
        const SizedBox(height: 10), Text('We’ll turn your receipt into an expense you can check before saving.',
            style: theme.bodyMedium?.copyWith(color: PocketColors.muted)),
        const SizedBox(height: 24),
        if (_photo != null) ClipRRect(borderRadius: BorderRadius.circular(24), child: SizedBox(height: 350,
          child: ColoredBox(color: const Color(0xFFE9EDE5), child: InteractiveViewer(maxScale: 4,
              child: Image.memory(_photo!.bytes, fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Center(child: Padding(padding: EdgeInsets.all(20),
                    child: Text('This photo cannot be previewed. Please choose a JPEG or PNG receipt.'))))))))
        else Container(height: 310, decoration: BoxDecoration(color: PocketColors.lime.withAlpha(170), borderRadius: BorderRadius.circular(28)),
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(child: CustomPaint(painter: _ScanFramePainter())),
            Transform.rotate(angle: -.08, child: Container(width: 145, height: 190, padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5), boxShadow: [BoxShadow(color: PocketColors.green.withAlpha(15), blurRadius: 24, offset: const Offset(0, 12))]),
              child: Column(children: [
                const Icon(Icons.spa_outlined, color: PocketColors.green, size: 28), const SizedBox(height: 14),
                for (final width in [85.0, 65.0, 85.0, 75.0]) Padding(padding: const EdgeInsets.only(bottom: 10),
                  child: Container(width: width, height: 4, decoration: BoxDecoration(color: PocketColors.line, borderRadius: BorderRadius.circular(2)))),
                const Spacer(), const Divider(), const SizedBox(height: 9),
                const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('TOTAL', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700)), Text('—', style: TextStyle(fontSize: 12))]),
              ]))),
          ])),
        const SizedBox(height: 16), Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.wb_sunny_outlined, color: PocketColors.muted, size: 18), const SizedBox(width: 9),
          Expanded(child: Text('Keep the whole receipt in frame, lay it flat, and use good light.', style: theme.bodySmall)),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 18), child: PocketCard(color: PocketColors.peach,
          padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: PocketColors.amber)))),
        const SizedBox(height: 24),
        if (_busy || _sampleBusy) PocketCard(child: Column(children: [
          const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(height: 14),
          Text(_sampleBusy ? 'Opening a sample receipt…' : 'Reading your receipt…', style: theme.titleSmall),
          const SizedBox(height: 6), Text(_sampleBusy ? 'No photo is uploaded for this preview.' : 'You’ll review all items and the total next.', style: theme.bodySmall),
        ]))
        else ...[
          if (_photo != null) FilledButton.icon(onPressed: _extract, icon: const Icon(Icons.auto_awesome_outlined, size: 20),
            label: Text(widget.service.isConfigured ? 'Extract receipt' : 'Connect & extract')),
          if (_photo != null) const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _photo == null
                ? FilledButton.icon(onPressed: () => _pick(ImageSource.camera), icon: const Icon(Icons.camera_alt_outlined, size: 20), label: const Text('Take photo'))
                : OutlinedButton.icon(onPressed: () => _pick(ImageSource.camera), icon: const Icon(Icons.camera_alt_outlined, size: 20), label: const Text('Retake'))),
            const SizedBox(width: 12), Expanded(child: OutlinedButton.icon(onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined, size: 20), label: const Text('Gallery'))),
          ]),
          const SizedBox(height: 16), TextButton(onPressed: _sample, child: const Text('Try a sample receipt')),
          if (!widget.service.isConfigured && widget.service is ConnectableReceiptService)
            OutlinedButton(onPressed: _connect, child: const Text('Connect receipt service')),
          if (!widget.service.isConfigured) Text('Connect your receipt service and sign in to read real photos. Sample receipts are available to explore.',
              textAlign: TextAlign.center, style: theme.bodySmall),
        ],
      ]),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: 215, height: 245);
    final paint = Paint()..color = PocketColors.green.withAlpha(110)..style = PaintingStyle.stroke..strokeWidth = 2..strokeCap = StrokeCap.round;
    const length = 22.0;
    for (final corner in [(rect.topLeft, 1.0, 1.0), (rect.topRight, -1.0, 1.0),
                          (rect.bottomLeft, 1.0, -1.0), (rect.bottomRight, -1.0, -1.0)]) {
      canvas.drawLine(corner.$1, corner.$1 + Offset(length * corner.$2, 0), paint);
      canvas.drawLine(corner.$1, corner.$1 + Offset(0, length * corner.$3), paint);
    }
  }
  @override
  bool shouldRepaint(covariant _ScanFramePainter oldDelegate) => false;
}
