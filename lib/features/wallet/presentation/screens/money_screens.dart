import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/glass_container.dart';
import '../../../../core/widgets/neon_button.dart';
import '../../data/wallet_api.dart';
import '../../domain/wallet_models.dart';
import '../../domain/wallet_strings.dart';
import '../providers/wallet_providers.dart';
import '../widgets/pin_pad.dart';
import '../widgets/wallet_widgets.dart';

/// Bottom sheet that lists what is about to happen; true when confirmed.
Future<bool> confirmSheet(BuildContext context, {required List<Widget> rows, required String button}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.glassBorder, borderRadius: BorderRadius.circular(4))),
            ),
            const SizedBox(height: 16),
            Text(WS.confirmTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            ...rows,
            const SizedBox(height: 20),
            NeonButton(label: button, icon: Icons.lock_rounded, onPressed: () => Navigator.of(context).pop(true)),
            const SizedBox(height: 6),
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(WS.cancel)),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

/// Big amount input with the currency switcher above it.
class AmountField extends ConsumerWidget {
  const AmountField({super.key, required this.controller, this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = ref.watch(selectedCurrencyProvider);
    final balance = ref.watch(walletAuthProvider).valueOrNull?.profile?.wallet(currency).balance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CurrencySwitcher(compact: true),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
          decoration: InputDecoration(
            labelText: WS.amount,
            suffixText: currencySymbol(currency),
            prefixIcon: const Icon(Icons.payments_outlined),
          ),
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
        ),
        if (balance != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6, top: 6),
            child: Text(
              '${WS.totalBalance}: ${formatMoney(balance, currency)}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}

/// Keeps one idempotency key per (what, amount, currency) so a retry never pays twice.
class _PayKey {
  String _for = '';
  String _key = '';

  String forPayment(String signature) {
    if (signature != _for) {
      _for = signature;
      _key = newIdempotencyKey();
    }
    return _key;
  }
}

// ---------------------------------------------------------------- send
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key, this.initialPhone});

  final String? initialPhone;

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  late final _phone = TextEditingController(text: widget.initialPhone ?? '');
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _key = _PayKey();
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _review() async {
    final api = ref.read(walletApiProvider);
    final currency = ref.read(selectedCurrencyProvider);
    final phone = _phone.text.trim();
    final amount = normalizeAmount(_amount.text, currency);
    if (phone.replaceAll(RegExp(r'\D'), '').length < 8) {
      showWalletError(context, 'invalid_phone');
      return;
    }
    if (amount == null) {
      showWalletError(context, 'invalid_amount');
      return;
    }

    setState(() => _busy = true);
    try {
      final party = await api.lookup(phone);
      final quote = await api.quote('transfer', amount, currency);
      if (!mounted) return;
      setState(() => _busy = false);
      final ok = await confirmSheet(
        context,
        button: WS.confirmAndPay,
        rows: [
          InfoRow(WS.to, party.name),
          InfoRow('', party.phone, ltr: true),
          const Divider(color: AppColors.glassBorder),
          InfoRow(WS.amount, formatMoney(quote.amount, currency), ltr: true),
          InfoRow(WS.fee, formatMoney(quote.fee, currency), ltr: true),
          InfoRow(WS.total, formatMoney(quote.total, currency), bold: true, ltr: true),
          if (_note.text.trim().isNotEmpty) InfoRow(WS.t('ملاحظة', 'Note'), _note.text.trim()),
        ],
      );
      if (!ok || !mounted) return;
      final pin = await askPin(context);
      if (pin == null || !mounted) return;
      setState(() => _busy = true);
      final txn = await api.transfer(
        toPhone: party.phone,
        amount: amount,
        currency: currency,
        pin: pin,
        note: _note.text.trim(),
        idempotencyKey: _key.forPayment('send|${party.phone}|$amount|$currency'),
      );
      if (!mounted) return;
      refreshWallet(ref);
      context.pushReplacement('/receipt/${txn.id}?done=1', extra: txn);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showWalletError(context, walletErrorCode(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return WalletPage(
      title: WS.sendTitle,
      child: ListView(
        padding: const EdgeInsets.only(top: 70),
        children: [
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: WS.recipient,
              prefixIcon: const Icon(Icons.person_search_rounded),
              suffixIcon: IconButton(
                tooltip: WS.scan,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                onPressed: () async {
                  final scanned = await context.push<String>('/scan?pick=1');
                  if (scanned != null) _phone.text = scanned;
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          AmountField(controller: _amount),
          const SizedBox(height: 18),
          TextField(
            controller: _note,
            maxLength: 140,
            decoration: InputDecoration(labelText: WS.note, prefixIcon: const Icon(Icons.edit_note_rounded)),
          ),
          const SizedBox(height: 18),
          NeonButton(label: WS.review, icon: Icons.arrow_forward_rounded, loading: _busy, onPressed: _review),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- request
class RequestMoneyScreen extends ConsumerStatefulWidget {
  const RequestMoneyScreen({super.key});

  @override
  ConsumerState<RequestMoneyScreen> createState() => _RequestMoneyScreenState();
}

class _RequestMoneyScreenState extends ConsumerState<RequestMoneyScreen> {
  final _phone = TextEditingController();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = ref.read(walletApiProvider);
    final currency = ref.read(selectedCurrencyProvider);
    final phone = _phone.text.trim();
    final amount = normalizeAmount(_amount.text, currency);
    if (phone.replaceAll(RegExp(r'\D'), '').length < 8) {
      showWalletError(context, 'invalid_phone');
      return;
    }
    if (amount == null) {
      showWalletError(context, 'invalid_amount');
      return;
    }
    setState(() => _busy = true);
    try {
      final party = await api.lookup(phone);
      if (!mounted) return;
      setState(() => _busy = false);
      final ok = await confirmSheet(
        context,
        button: WS.sendRequest,
        rows: [
          InfoRow(WS.from, party.name),
          InfoRow('', party.phone, ltr: true),
          InfoRow(WS.amount, formatMoney(amount, currency), bold: true, ltr: true),
        ],
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      await api.createRequest(fromPhone: party.phone, amount: amount, currency: currency, note: _note.text.trim());
      if (!mounted) return;
      ref.invalidate(requestsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(WS.requestSent), backgroundColor: AppColors.emerald.withValues(alpha: 0.9), behavior: SnackBarBehavior.floating),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showWalletError(context, walletErrorCode(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return WalletPage(
      title: WS.requestTitle,
      child: ListView(
        padding: const EdgeInsets.only(top: 70),
        children: [
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            decoration: InputDecoration(labelText: WS.requestFrom, prefixIcon: const Icon(Icons.person_search_rounded)),
          ),
          const SizedBox(height: 18),
          AmountField(controller: _amount),
          const SizedBox(height: 18),
          TextField(
            controller: _note,
            maxLength: 140,
            decoration: InputDecoration(labelText: WS.note, prefixIcon: const Icon(Icons.edit_note_rounded)),
          ),
          const SizedBox(height: 18),
          NeonButton(label: WS.sendRequest, icon: Icons.send_rounded, loading: _busy, onPressed: _send),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- top up / withdraw
class TopUpScreen extends ConsumerStatefulWidget {
  const TopUpScreen({super.key, this.withdraw = false});

  final bool withdraw;

  @override
  ConsumerState<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends ConsumerState<TopUpScreen> {
  final _amount = TextEditingController();
  final _key = _PayKey();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final api = ref.read(walletApiProvider);
    final currency = ref.read(selectedCurrencyProvider);
    final amount = normalizeAmount(_amount.text, currency);
    if (amount == null) {
      showWalletError(context, 'invalid_amount');
      return;
    }
    final key = _key.forPayment('${widget.withdraw ? 'out' : 'in'}|$amount|$currency');
    setState(() => _busy = true);
    try {
      final WalletTxn txn;
      if (widget.withdraw) {
        final quote = await api.quote('withdraw', amount, currency);
        if (!mounted) return;
        setState(() => _busy = false);
        final ok = await confirmSheet(
          context,
          button: WS.confirmAndPay,
          rows: [
            InfoRow(WS.amount, formatMoney(quote.amount, currency), ltr: true),
            InfoRow(WS.fee, formatMoney(quote.fee, currency), ltr: true),
            InfoRow(WS.total, formatMoney(quote.total, currency), bold: true, ltr: true),
          ],
        );
        if (!ok || !mounted) return;
        final pin = await askPin(context);
        if (pin == null || !mounted) return;
        setState(() => _busy = true);
        txn = await api.withdraw(amount: amount, currency: currency, pin: pin, idempotencyKey: key);
      } else {
        txn = await api.topUp(amount: amount, currency: currency, idempotencyKey: key);
      }
      if (!mounted) return;
      refreshWallet(ref);
      context.pushReplacement('/receipt/${txn.id}?done=1', extra: txn);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showWalletError(context, walletErrorCode(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(selectedCurrencyProvider);
    final quick = currency == 'JOD' ? ['20', '50', '100', '200'] : ['50', '100', '200', '500'];
    return WalletPage(
      title: widget.withdraw ? WS.withdrawTitle : WS.topUpTitle,
      child: ListView(
        padding: const EdgeInsets.only(top: 70),
        children: [
          GlassContainer(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(widget.withdraw ? Icons.account_balance_rounded : Icons.science_outlined, color: AppColors.amber),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.withdraw ? WS.withdrawHint : WS.topUpHint, style: const TextStyle(color: AppColors.textSecondary))),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AmountField(controller: _amount, onSubmitted: _go),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in quick)
                ActionChip(
                  label: Text(formatMoney(q, currency)),
                  onPressed: () => _amount.text = q,
                  side: const BorderSide(color: AppColors.glassBorder),
                ),
            ],
          ),
          const SizedBox(height: 24),
          NeonButton(
            label: widget.withdraw ? WS.review : WS.topUp,
            icon: widget.withdraw ? Icons.arrow_forward_rounded : Icons.add_rounded,
            loading: _busy,
            onPressed: _go,
          ),
        ],
      ),
    );
  }
}
