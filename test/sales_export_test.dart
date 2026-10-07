import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/admin/domain/sales_export.dart';

void main() {
  test('sales export creates one workbook row per settled payment', () {
    final bytes = SalesSpreadsheet.create([
      SalesExportRow(
        settledAt: DateTime.utc(2026, 9, 20, 10),
        orderId: 'order-1',
        clientName: 'Ari Client',
        freelancerName: 'Sam Seller',
        method: 'Xendit',
        gross: 500,
        commission: 50,
        netToFreelancer: 450,
      ),
    ]);

    final workbook = Excel.decodeBytes(bytes);
    final sheet = workbook.tables['Sales'];
    expect(sheet, isNotNull);
    expect(sheet!.maxRows, 2);
    expect(
      sheet.cell(CellIndex.indexByString('C2')).value,
      TextCellValue('Ari Client'),
    );
    expect(sheet.cell(CellIndex.indexByString('H2')).value, IntCellValue(450));
  });
}
