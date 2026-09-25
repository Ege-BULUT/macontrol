## Summary

<!-- What this changes and why, in a few sentences. -->

## Changes

<!-- Grouped by module, for example **Safety (`Sources/Safety`)**, **UI (`Sources/MacontrolUI`)**, **Tests**. -->

-

## Testing

<!-- What you ran and what it showed. Name the tests that cover the change. For a new safety check, say which deliberate bug made its test fail. -->

- `swift build && swift test`:

## Notes

<!-- Known limits, follow-ups, decisions that need sign-off. End with the board task. -->

- Board: T-

## Checklist

- [ ] `swift build` and `swift test` pass.
- [ ] UI changes come with light and dark snapshots (`--snapshot`).
- [ ] Anything that deletes or moves files goes through `Sources/Safety` and has a test.
- [ ] `CHANGELOG.md` is updated for user-facing changes.
- [ ] The board task is referenced (for example "Board: T-0079").
