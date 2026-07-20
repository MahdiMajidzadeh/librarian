# _contexts — living documentation for Librarian

These files describe what the app is, how it's built, what it does, and how
its core logic works. They are the reference to consult **before** making any
change, and they must be kept in sync with the code **after** every change.

## Files

| File | Contents |
|---|---|
| [01-overview.md](01-overview.md) | What the app is, the problem it solves, hard invariants |
| [02-development.md](02-development.md) | Toolchain, build/test commands, project layout, conventions |
| [03-features.md](03-features.md) | Feature inventory, UI surface, settings |
| [04-logic.md](04-logic.md) | How each subsystem works: scan, grouping, metadata, lookup, rename, export |

## Development workflow (mandatory)

1. **Before developing**: read the relevant context file(s). If the requested
   change is consistent with the documented design and invariants, proceed.
2. **If the change conflicts** with a documented invariant or design decision
   (e.g. would move user files, overwrite manual edits, bypass the rename
   preview), **stop and check with the user** before writing code.
3. **After developing**: update the affected context file(s) so they describe
   the code as it now is.
4. **After any development**: run `swift build` and `swift test`, and verify
   the app launches: `.build/debug/Librarian & sleep 3; kill -0 $!`
