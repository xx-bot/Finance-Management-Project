import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/receipt_service.dart';
import '../components/common.dart';
import '../theme.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key, required this.service});
  final ConnectableReceiptService service;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _url, _email;
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.service.baseUrl.isNotEmpty
        ? widget.service.baseUrl : kDebugMode ? 'http://127.0.0.1:8080' : '');
    _email = TextEditingController(text: widget.service.accountEmail ?? '');
  }

  @override
  void dispose() {
    _url.dispose(); _email.dispose(); _password.dispose();
    super.dispose();
  }

  String _message(Object error) => error is ReceiptServiceException
      ? error.message : 'Could not complete this request. Please try again.';

  Future<void> _check() async {
    if (!BackendReceiptService.validBaseUrl(_url.text)) {
      setState(() => _error = 'Enter a valid HTTP or HTTPS server address.');
      return;
    }
    setState(() { _busy = true; _error = null; _notice = null; });
    try {
      final message = await widget.service.checkConnection(_url.text);
      if (mounted) setState(() => _notice = message);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() { _busy = true; _error = null; _notice = null; });
    try {
      await widget.service.authenticate(baseUrl: _url.text, email: _email.text,
          password: _password.text, register: _register);
      if (!mounted) return;
      TextInput.finishAutofillContext();
      Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() { _busy = true; _error = null; _notice = null; });
    try {
      await widget.service.signOut();
      _password.clear();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final theme = Theme.of(context).textTheme;
      final connected = widget.service.isConfigured;
      return PopScope(canPop: !_busy, child: Scaffold(
        appBar: AppBar(title: const Text('Receipt service'), centerTitle: true),
        body: SafeArea(child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: AbsorbPointer(absorbing: _busy, child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
            children: [
              Text(connected ? 'Your receipts are connected.' : 'Connect your receipts.', style: theme.headlineMedium),
              const SizedBox(height: 10),
              Text('Sign in to your receipt service to read photos and review the extracted items.', style: theme.bodyMedium),
              const SizedBox(height: 24),
              if (connected) ...[
                PocketCard(color: PocketColors.lime, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.check_circle_outline, color: PocketColors.green),
                  const SizedBox(height: 12),
                  Text(widget.service.accountEmail ?? 'Session connected', style: theme.titleMedium),
                  const SizedBox(height: 8), SelectableText(widget.service.baseUrl, style: theme.bodySmall),
                  const SizedBox(height: 18),
                  const Text('Signing out keeps your saved expenses on this device.'),
                ])),
                const SizedBox(height: 20),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: _signOut, child: const Text('Sign out')),
              ] else Form(key: _form, child: AutofillGroup(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextFormField(controller: _url, keyboardType: TextInputType.url,
                  autocorrect: false, textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://your-server.example'),
                  validator: (value) => BackendReceiptService.validBaseUrl(value ?? '') ? null : 'Enter a valid HTTP or HTTPS address.'),
                if (kDebugMode) const Padding(padding: EdgeInsets.only(top: 8), child: Text(
                  'For USB development, keep your phone connected and forward port 8080. A Wi-Fi or hosted server uses its own address.',
                  style: TextStyle(fontSize: 12, color: PocketColors.muted))),
                Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                  onPressed: _check, icon: const Icon(Icons.wifi_find, size: 19), label: const Text('Check connection'))),
                const SizedBox(height: 12),
                SegmentedButton<bool>(segments: const [
                  ButtonSegment(value: false, label: Text('Sign in')),
                  ButtonSegment(value: true, label: Text('Create account')),
                ], selected: {_register}, onSelectionChanged: (value) => setState(() { _register = value.single; _error = null; })),
                const SizedBox(height: 20),
                TextFormField(controller: _email, keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next, autofillHints: const [AutofillHints.email],
                  autocorrect: false, decoration: const InputDecoration(labelText: 'Email'),
                  validator: (value) => value != null && value.trim().contains('@') ? null : 'Enter your email address.'),
                const SizedBox(height: 12),
                TextFormField(controller: _password, obscureText: _hidePassword,
                  autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                  textInputAction: TextInputAction.done, onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(labelText: 'Password', helperText: _register ? 'At least 8 characters.' : null,
                    suffixIcon: IconButton(tooltip: _hidePassword ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _hidePassword = !_hidePassword),
                      icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined))),
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'Enter your password.';
                    if (_register && (value.runes.length < 8 || utf8.encode(value).length > 72)) return 'Use at least 8 characters and at most 72 UTF-8 bytes.';
                    return null;
                  }),
                const SizedBox(height: 22),
                FilledButton(onPressed: _submit, child: Text(_register ? 'Create account & connect' : 'Sign in & connect')),
                const SizedBox(height: 16),
                Text('Your session is saved securely on this device. Expense synchronization is not enabled yet.', style: theme.bodySmall),
              ]))),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 20), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 18),
                child: PocketCard(color: PocketColors.peach, child: Text(_error!, style: const TextStyle(color: PocketColors.amber)))),
              if (_notice != null) Padding(padding: const EdgeInsets.only(top: 18),
                child: PocketCard(color: PocketColors.lime, child: Text(_notice!))),
            ],
          )),
        ))),
      ));
    },
  );
}
