import 'dart:typed_data';

import 'package:excel/excel.dart';

/// One settled payment, with names resolved only for a staff export. Names
/// are not copied into payment documents, so profile updates remain canonical.
class SalesExportRow {
  const SalesExportRow({
    required this.settledAt,
    required this.orderId,
    required this.clientName,
    required this.freelancerName,
    required this.method,
    required this.gross,
    required this.commission,
    required this.netToFreelancer,
  });

  final DateTime settledAt;
  final String orderId;
  final String clientName;
  final String freelancerName;
  final String method;
  final int gross;
  final int commission;
  final int netToFreelancer;
}

/// Produces a real XLSX workbook rather than a CSV renamed to `.xlsx`.
abstract final class SalesSpreadsheet {
  static Uint8List create(
    List<SalesExportRow> rows, {
    String fileName = 'sales.xlsx',
  }) {
    final excel = Excel.createExcel();
    final initialSheet = excel.getDefaultSheet();
    if (initialSheet != null && initialSheet != 'Sales') {
      excel.rename(initialSheet, 'Sales');
    }
    final sheet = excel['Sales'];
    sheet.appendRow([
      TextCellValue('Settled at'),
      TextCellValue('Order'),
      TextCellValue('Client'),
      TextCellValue('Freelancer'),
      TextCellValue('Method'),
      TextCellValue('Gross (PHP)'),
      TextCellValue('Commission (PHP)'),
      TextCellValue('Seller net (PHP)'),
    ]);
    for (final row in rows) {
      sheet.appendRow([
        TextCellValue(row.settledAt.toIso8601String()),
        TextCellValue(row.orderId),
        TextCellValue(row.clientName),
        TextCellValue(row.freelancerName),
        TextCellValue(row.method),
        IntCellValue(row.gross),
        IntCellValue(row.commission),
        IntCellValue(row.netToFreelancer),
      ]);
    }
    final bytes = excel.save(fileName: fileName);
    if (bytes == null) throw StateError('Could not create the sales workbook.');
    return Uint8List.fromList(bytes);
  }
}
