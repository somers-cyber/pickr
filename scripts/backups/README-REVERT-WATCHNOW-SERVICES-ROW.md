# Revert: Watch Now services row experiment

If you want to **restore the previous layout** (mood chips in the top row; streaming filters in the sheet from the header button):

```bash
cp "scripts/backups/TonightsPickView.swift.before-watchnow-services-row-20260327" "moviefinder/TonightsPickView.swift"
```

Backup saved: `TonightsPickView.swift.before-watchnow-services-row-20260327`

This experiment also added `StreamingService.watchNowChipTitle` in `StreamingAggregator.swift`. To fully undo:

- Remove the `watchNowChipTitle` computed property and its closing brace from `StreamingService` (keep the static `all` array as before).
