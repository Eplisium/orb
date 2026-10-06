## Summary

<!-- What does this change and why? Link issues with "Fixes #123". -->

## Changes

-

## Testing

- [ ] `swift build --build-tests` succeeds and the warning count did not go up (`scripts/count_warnings.sh`)
- [ ] `swift test` passes
- [ ] New or changed behavior is covered by Swift Testing tests (offline: no Keychain, network, or production DB)
- [ ] UI changes checked in the packaged app (`bash build_app.sh --adhoc`), with screenshots below if visual

## Checklist

- [ ] No secrets, `codesign/` material, `.env` files, or `/Users/<name>` paths in the diff
- [ ] `CHANGELOG.md` updated under *Unreleased* (if user-visible)
- [ ] README / `docs/ARCHITECTURE.md` updated (if behavior or structure changed)
- [ ] Security-sensitive paths fail closed and have denial-path tests (if applicable)

## Screenshots

<!-- Optional -->
