/// Parses a grid cell string for totals: long-press pairs use `/`, tap pairs use `,`.
double parseSheetCellNumericValue(String value) {
  if (value.isEmpty) return 0.0;

  if (value.contains('/')) {
    final parts = value.split('/');
    if (parts.length == 2) {
      final part1 = double.tryParse(parts[0].trim()) ?? 0.0;
      final part2 = double.tryParse(parts[1].trim()) ?? 0.0;
      return part1 + part2;
    }
  }

  if (value.contains(',')) {
    final parts = value.split(',');
    if (parts.length == 2) {
      final part1 = double.tryParse(parts[0].trim()) ?? 0.0;
      final part2 = double.tryParse(parts[1].trim()) ?? 0.0;
      return part1 + part2;
    }
  }

  return double.tryParse(value.trim()) ?? 0.0;
}
