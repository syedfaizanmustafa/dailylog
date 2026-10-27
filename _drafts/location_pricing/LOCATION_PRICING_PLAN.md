# Per-location prices — built Oct 18, 2026

**Status:** built from the decisions below. The code is in the app (not the drafts). This folder keeps the original Oct 9 drafts for reference only.

## Decisions (Oct 18)
1. Nobody changes prices on the sheet. Staff (and admins) can still change a row's **Total Paid** for each material, e.g. for a discount. Admins change prices in **Locations › Prices**.
2. Existing sheets and rows already entered stay as they are. Prices are never recalculated.
   **Update (Oct 18):** an entry keeps the prices it started with. A price update only applies to entries started after it, including new rows on an entry already in progress.
3. No allowed price ranges (any number ≥ 0, at most 4 decimals).
4. No "big change" check. The save step just lists old → new.
5. A price change takes effect right away for new entries, on every device.
6. Other commodities get per-location prices too, per CODE (BI, P#2–P#7, WDS, MLP, BIB, CC, SCRAP). An empty code stays priced by hand. 0 is allowed (scrap).

## How it works
- **Data:** `locations/{id}.prices` = `{aluminum, glass, pete, other: {code: price}, updatedAt, updatedByUid, updatedByName}`, plus `priceHistory` (last 30 saves, newest first). Saved in one transaction.
- **Admin:** each location card shows its prices (or "Prices not set · sheets use standard prices") and an **Edit prices** / **Set prices** button. The editor has the three main prices, one optional field per other code, "copy from another location", and the price history.
- **New Entry:**
  - Follows the location's prices live: the override location if an admin picked one, else the nearest.
  - Standard prices ($1.80 / $0.101 / $1.46) apply while the location's prices load, or when it has none.
  - Paid = SW × price, filled when SW is entered. Other commodities: col 19 = SW (col 16) × price of the row's CODE.
  - While the entry is empty it follows the location's prices, including when the location is switched. Once it has a row, its prices are locked (saved with the draft) until it is submitted.
  - The price sheet says when an entry is locked.
  - Tapping a section's SW header shows the prices (read-only). Admins get a shortcut to edit them.
  - The code picker shows each code's price.
  - Each submitted sheet saves `prices: {aluminum, glass, pete, other, source: location|standard, locationId}`.
- **View Entry:**
  - Saving edits keeps the sheet's other fields (customerNames, prices).
  - The phone row editor uses the sheet's saved prices for SW → paid, never today's prices.

## Files
- `lib/models/location_prices.dart`: model, parsing, transaction save, providers, other-commodity code list.
- `lib/widgets/location_price_editor.dart`: admin editor bottom sheet.
- `lib/screens/locations_screen.dart`: prices strip on each card.
- `lib/screens/new_entry_screen.dart`: live prices, read-only price sheet, other-commodity auto paid, prices saved per sheet.
- `lib/screens/view_entry_screen.dart`, `view_entry_phone.dart`: keep sheet fields; editor uses the sheet's prices.

## Test checklist
- Set prices for a location, then confirm on an iPad at that location that a new row's paid uses them.
- Change a price while an entry has rows: new rows on that entry still use the old price; a new entry uses the new price. Same after closing and reopening the draft.
- Staff tapping the SW header see prices but can't edit them. Typing a lower Total Paid works.
- Other: pick P#2 with a price → paid fills from SW. Pick a code with no price → typed by hand. SCRAP at 0 → $0.00, and the receipt is issued.
- Submit, then check `sheets.N.prices` in Firestore.
- Edit that sheet in View Entry: customer names and prices are still on the sheet.
