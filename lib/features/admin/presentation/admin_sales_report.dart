import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../chat/data/chat_repository.dart';
import '../../payments/domain/payment.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../data/admin_repository.dart';
import '../domain/sales_export.dart';

enum _SalesRange { all, week, month }

extension on _SalesRange {
  String get label => switch (this) {
    _SalesRange.all => 'All time',
    _SalesRange.week => 'Last 7 days',
    _SalesRange.month => 'Last 30 days',
  };

  DateTime? get start => switch (this) {
    _SalesRange.all => null,
    _SalesRange.week => DateTime.now().subtract(const Duration(days: 7)),
    _SalesRange.month => DateTime.now().subtract(const Duration(days: 30)),
  };
}

/// Settled sales only. The report intentionally does not call pending
/// checkouts sales: a client opening a gateway page is not revenue.
class SalesReportScreen extends StatefulWidget {
  const SalesReportScreen({super.key});

  @override
  State<SalesReportScreen> createState() => _SalesReportScreenState();
}

class _SalesReportScreenState extends State<SalesReportScreen> {
  _SalesRange _range = _SalesRange.all;
  late Stream<List<Payment>> _sales;
  List<Payment> _latestSales = const [];
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _sales = context.read<AdminRepository>().watchSales(from: _range.start);
  }

  void _selectRange(_SalesRange range) {
    setState(() {
      _range = range;
      _load();
    });
  }

  Future<void> _export() async {
    if (_exporting || _latestSales.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final names = await _namesFor(_latestSales);
      final rows = [
        for (final payment in _latestSales)
          SalesExportRow(
            settledAt: payment.paidAt ?? payment.updatedAt,
            orderId: payment.orderId,
            clientName: names[payment.clientId] ?? 'Former student',
            freelancerName: names[payment.freelancerId] ?? 'Former student',
            method: payment.method.label,
            gross: payment.amount,
            commission: payment.commission,
            netToFreelancer: payment.netToFreelancer,
          ),
      ];
      final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final bytes = SalesSpreadsheet.create(
        rows,
        fileName: 'sales-$stamp.xlsx',
      );
      // `excel.save` already starts the browser download on web. Native
      // platforms still need a saver to write those workbook bytes.
      if (!kIsWeb) {
        await FileSaver.instance.saveAs(
          name: 'sales-$stamp',
          bytes: bytes,
          fileExtension: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kIsWeb
                  ? 'Your Excel download has started.'
                  : 'Sales report saved as sales-$stamp.xlsx.',
            ),
          ),
        );
      }
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } on Exception {
      if (mounted) {
        showFailureSnackBar(context, 'Could not export the sales report.');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Map<String, String>> _namesFor(List<Payment> payments) async {
    final repository = context.read<ChatRepository>();
    final ids = {
      for (final payment in payments) payment.clientId,
      for (final payment in payments) payment.freelancerId,
    };
    final entries = await Future.wait(
      ids.map(
        (id) async => MapEntry(id, (await repository.summaryOf(id)).name),
      ),
    );
    return Map.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        actions: [
          IconButton(
            tooltip: 'Export to Excel',
            onPressed: _exporting || _latestSales.isEmpty ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 54,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                for (final range in _SalesRange.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(range.label),
                      selected: range == _range,
                      onSelected: (_) => _selectRange(range),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Payment>>(
              stream: _sales,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const ErrorView(message: 'Could not load sales.');
                }
                if (!snapshot.hasData) return const LoadingView();
                final sales = snapshot.data!;
                _latestSales = sales;
                if (sales.isEmpty) {
                  return EmptyView(
                    message:
                        'No settled sales for ${_range.label.toLowerCase()}.',
                    icon: Icons.payments_outlined,
                  );
                }
                return _SalesFinancialReport(sales: sales, range: _range);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SalesFinancialReport extends StatelessWidget {
  const _SalesFinancialReport({required this.sales, required this.range});

  final List<Payment> sales;
  final _SalesRange range;

  @override
  Widget build(BuildContext context) {
    final figures = _SalesFigures.fromPayments(sales);
    final dates =
        sales.map((payment) => payment.paidAt ?? payment.updatedAt).toList()
          ..sort();
    final dateFormat = DateFormat.yMMMd();
    final period = range == _SalesRange.all
        ? '${dateFormat.format(dates.first)} to ${dateFormat.format(dates.last)}'
        : range.label;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ReportHeading(period: period, figures: figures),
        const SectionHeader(
          'Settlement composition',
          subtitle: 'How the report-period sales were confirmed and held.',
        ),
        _SettlementComposition(figures: figures),
        const SectionHeader(
          'Settlement ledger',
          subtitle: 'One row per settled payment. Amounts are Philippine pesos (PHP).',
        ),
        _SettlementLedger(sales: sales),
      ],
    );
  }
}

class _ReportHeading extends StatelessWidget {
  const _ReportHeading({required this.period, required this.figures});

  final String period;
  final _SalesFigures figures;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LilyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Financial sales report', style: theme.textTheme.titleLarge),
          const SizedBox(height: 2),
          Text('Settlement period: $period', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            'Settled payments only. Pending checkouts and refunded payments are excluded.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _Figure(
                label: 'Gross settled sales',
                value: pesos(figures.gross),
                caption:
                    '${figures.count} payment${figures.count == 1 ? '' : 's'}',
                emphasis: true,
              ),
              _Figure(
                label: 'Platform commission',
                value: pesos(figures.commission),
                caption: 'Recognized platform fee',
              ),
              _Figure(
                label: 'Seller entitlement',
                value: pesos(figures.sellerNet),
                caption: 'Gross less commission',
              ),
              _Figure(
                label: 'Average sale',
                value: pesos(figures.averageSale),
                caption: 'Gross per settled payment',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Gross settled sales = platform commission + seller entitlement. '
            'Payout transfers and tax treatment are not included in this report.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.caption,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final String caption;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 174,
      child: StatTile(
        label: label,
        value: value,
        caption: caption,
        emphasis: emphasis,
      ),
    );
  }
}

class _SettlementComposition extends StatelessWidget {
  const _SettlementComposition({required this.figures});

  final _SalesFigures figures;

  @override
  Widget build(BuildContext context) {
    return LilyPanel(
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        children: [
          _CompositionFigure(
            label: 'Gateway-confirmed sales',
            value: pesos(figures.gatewayGross),
            note:
                '${figures.gatewayCount} payment${figures.gatewayCount == 1 ? '' : 's'} with a gateway receipt',
          ),
          _CompositionFigure(
            label: 'Directly attested sales',
            value: pesos(figures.directGross),
            note:
                '${figures.directCount} payment${figures.directCount == 1 ? '' : 's'} confirmed by the freelancer',
          ),
          _CompositionFigure(
            label: 'Seller funds held',
            value: pesos(figures.heldSellerNet),
            note: 'Seller entitlement still in platform custody',
          ),
          _CompositionFigure(
            label: 'Released to wallets',
            value: pesos(figures.releasedSellerNet),
            note: 'Seller entitlement credited to the in-app wallet',
          ),
        ],
      ),
    );
  }
}

class _CompositionFigure extends StatelessWidget {
  const _CompositionFigure({
    required this.label,
    required this.value,
    required this.note,
  });

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(value, style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(note, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SettlementLedger extends StatelessWidget {
  const _SettlementLedger({required this.sales});

  final List<Payment> sales;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMMMd().add_jm();
    return LilyPanel(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Settled at')),
            DataColumn(label: Text('Client')),
            DataColumn(label: Text('Freelancer')),
            DataColumn(label: Text('Method / evidence')),
            DataColumn(label: Text('Custody')),
            DataColumn(label: Text('Gross'), numeric: true),
            DataColumn(label: Text('Commission'), numeric: true),
            DataColumn(label: Text('Seller net'), numeric: true),
          ],
          rows: [
            for (final payment in sales)
              DataRow(
                cells: [
                  DataCell(
                    Text(
                      dateFormat.format(payment.paidAt ?? payment.updatedAt),
                    ),
                  ),
                  DataCell(UserName(uid: payment.clientId)),
                  DataCell(UserName(uid: payment.freelancerId)),
                  DataCell(_SettlementEvidence(payment: payment)),
                  DataCell(_CustodyStatus(payment: payment)),
                  DataCell(Text(pesos(payment.amount))),
                  DataCell(Text(pesos(payment.commission))),
                  DataCell(Text(pesos(payment.netToFreelancer))),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SettlementEvidence extends StatelessWidget {
  const _SettlementEvidence({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(payment.method.label),
        Text(
          payment.verified ? 'Gateway-confirmed' : 'Freelancer-attested',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _CustodyStatus extends StatelessWidget {
  const _CustodyStatus({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = switch (payment.holdStatus) {
      HoldStatus.held => ('Held by platform', Tone.active),
      HoldStatus.released => ('Released to wallet', Tone.success),
      HoldStatus.refunded => ('Refunded', Tone.neutral),
      null => ('Paid directly', Tone.neutral),
    };
    return StatusPill(label: label, tone: tone, dense: true);
  }
}

class _SalesFigures {
  const _SalesFigures({
    required this.count,
    required this.gross,
    required this.commission,
    required this.sellerNet,
    required this.gatewayGross,
    required this.gatewayCount,
    required this.directGross,
    required this.directCount,
    required this.heldSellerNet,
    required this.releasedSellerNet,
  });

  final int count;
  final int gross;
  final int commission;
  final int sellerNet;
  final int gatewayGross;
  final int gatewayCount;
  final int directGross;
  final int directCount;
  final int heldSellerNet;
  final int releasedSellerNet;

  int get averageSale => count == 0 ? 0 : gross ~/ count;

  factory _SalesFigures.fromPayments(List<Payment> payments) {
    int sum(Iterable<Payment> values, int Function(Payment) field) =>
        values.fold(0, (total, payment) => total + field(payment));
    final gateway = payments.where((payment) => payment.verified);
    final direct = payments.where((payment) => !payment.verified);
    return _SalesFigures(
      count: payments.length,
      gross: sum(payments, (payment) => payment.amount),
      commission: sum(payments, (payment) => payment.commission),
      sellerNet: sum(payments, (payment) => payment.netToFreelancer),
      gatewayGross: sum(gateway, (payment) => payment.amount),
      gatewayCount: gateway.length,
      directGross: sum(direct, (payment) => payment.amount),
      directCount: direct.length,
      heldSellerNet: sum(
        payments.where((payment) => payment.holdStatus == HoldStatus.held),
        (payment) => payment.netToFreelancer,
      ),
      releasedSellerNet: sum(
        payments.where((payment) => payment.holdStatus == HoldStatus.released),
        (payment) => payment.netToFreelancer,
      ),
    );
  }
}
