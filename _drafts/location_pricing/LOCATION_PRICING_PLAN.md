# Per-location prices — plan & draft (on hold)

**Status:** paused on Oct 9, 2026. **Nothing is in the app yet.** The drafted code is saved next to this file and has not been compiled or reviewed.

## Goal
Admins set the $/lb price for each material **per location**. New Entry uses those prices to fill *Total Paid* from the SW weight. Any mistake here puts wrong money on sheets and receipts, so most of the design is about stopping mistakes.

## How prices work today
- New Entry has three hard-coded prices, editable by **anyone** on the sheet by tapping the section header:
  - Aluminum **$1.80**/lb
  - Glass **$0.101**/lb
  - PETE **$1.46**/lb
- Paid = SW weight × price, rounded to cents (`_updatePaidFromSw`). Other commodities are priced by hand.
- The price is saved in the device draft only. It is **not** saved with the submitted sheet, so there is no record of what price was used.
- Bug found: on the price dialog, `0` is accepted.

## Design

### Data (on `locations/{id}`)
- `prices`: `{aluminum, glass, pete, updatedAt, updatedByUid, updatedByName}`
- `priceHistory`: the last 30 changes, newest first. Each is `{at, byUid, byName, aluminum, glass, pete, previous}`.
- Saved in **one transaction**, so the price and its history always match.
- No rules change is needed, because location writes are already admin-only.

### Admin: Locations › Prices
- Each location card has a prices strip, e.g. "Alum. $1.80 · Glass $0.101 · PETE $1.46 per lb", with an **Edit prices** button. If no prices are set, it shows a red "Prices not set" warning.
- **Editor:**
  - One field per material, with `$` before it and `/ lb` after it.
  - Live check while typing:
    - numbers only;
    - at most 4 decimals;
    - allowed range per material: Aluminum $0.10–$10.00, Glass $0.01–$1.00, PETE $0.10–$10.00.
  - Hints under each field: "Now $1.80" and "10 lb pays $18.00".
  - A % change chip next to each field: amber, or red if the change is over 25%.
  - **Copy prices from another location.**
  - Price history (who / when / values).
- **Review step before saving:**
  - Shows old → new with % change for each material.
  - Any change over 25% is shown in red, and the admin must tick **"I double-checked these prices"** (this catches 18.0 typed instead of 1.80).
  - Explains that prices apply to new sheets and that rows already entered keep their amounts.

### New Entry
- **Sheet still empty:** it quietly switches to the location's prices.
- **Sheet already has rows**, and the location's prices differ (a draft was restored, the admin changed prices mid-day, or the location was switched):
  - A blue banner lists the differences (e.g. "Aluminum $1.85 (sheet $1.80)").
  - Buttons: **Keep sheet prices** or **Use new prices**.
  - Switching only affects rows entered afterwards. **Amounts already on the sheet are never recalculated.**
- **No prices set for the location:** an amber banner says the sheet uses standard prices and that an admin can set them.
- **Staff** can no longer change prices on the sheet. They get "Prices are set by an admin in Locations › Prices."
- **Admins** can still override a price for this sheet only, with the same validation. After that, prices are never auto-switched on that sheet.
- Each submitted sheet saves the prices used, as an audit trail: `prices: {aluminum, glass, pete, source: location|standard|edited, locationId}`.
- Price labels show 3 decimals when needed ($0.101 instead of $0.10).
- Draft keeps: `pricesFromLocation`, `priceBannerDismissed`, `pricesEditedHere`.

### Related fix found on the way
- When View Entry saves an edit (`_saveChanges`), it rewrites each sheet with only `data` / `hasSignatures` / `signatureCount`. It **drops** `customerNames`, and would drop the new `prices` too.
- The fix keeps the sheet's other fields. It's a 7-line patch in `view_entry_screen.patch`, worth applying even without pricing.

## Decisions to confirm before building
1. Staff can't change prices on the sheet (admin override only). OK?
2. Never recalculate rows already entered when prices change. OK?
3. Are the allowed ranges right? (Alum $0.10–10, Glass $0.01–1, PETE $0.10–10)
4. Is the 25% "big change" threshold for the extra check OK?
5. Should prices ever differ by date (e.g. start next Monday), or always take effect immediately?
6. Should **Other commodities** codes (HDPE, PP…) also get per-location prices?

## Files in this folder
| File | What it is |
|---|---|
| `location_prices.dart.txt` | New `lib/models/location_prices.dart`: price model, validation, transaction save, providers |
| `location_price_editor.dart.txt` | New `lib/widgets/location_price_editor.dart`: admin editor bottom sheet + review dialog |
| `locations_screen.patch` | Prices strip on each location card + opens the editor |
| `new_entry_screen.patch` | Banner, auto-switch on empty sheets, admin-only override with validation, draft keys, `prices` saved per sheet |
| `view_entry_screen.patch` | Keep sheet fields (customerNames, prices) when View Entry saves edits |

## To resume
1. Answer the 6 questions above.
2. Rename the two `.txt` files to `.dart` and put them in `lib/models/` and `lib/widgets/`.
3. Apply the patches: from the project root, run `patch -p0` or apply them in the IDE. The patches were made against the Oct 9 versions of these files, so they may need a refresh if the files changed since.
4. Have the code reviewed, then run `flutter analyze` and test:
   - an empty sheet picks up the location's prices;
   - a sheet with rows shows the banner;
   - staff are blocked from editing prices;
   - an admin override works;
   - big-change saves need the tick box;
   - history is recorded;
   - the submitted sheet has `prices`.
