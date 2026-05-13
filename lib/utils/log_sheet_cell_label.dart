/// Column short names for each grid column (22 columns; matches New Entry layout).
const kLogSheetColumnHeaders = <String>[
  'SW', 'SC', 'C', 'SP', 'ALUMINIUM',
  'SW', 'SC', 'C', 'SP', 'GLASS',
  'SW', 'SC', 'C', 'SP', 'PETE',
  'CODE',
  'SW', 'SC', 'C', 'SP', 'OTHER PAID',
  'SIGN/ID',
];

/// Human-readable cell title, e.g. `SW · Row 3`.
String logSheetCellTitle(int row, int col) {
  final name =
      col >= 0 && col < kLogSheetColumnHeaders.length
          ? kLogSheetColumnHeaders[col]
          : 'Column ${col + 1}';
  return '$name · Row ${row + 1}';
}
