# Agent Instructions

## Complexity budget

Before adding state machines, retries, receipts, replay systems, multiple deadlines, or generalized abstractions, compare them against the simplest direct fixed-hardware design. If one service, one state file, or one bounded operation solves the problem safely, use that. When a fix adds another coordination layer, stop and ask whether existing complexity should be removed instead.

Bugs caused by orchestration complexity should normally be fixed by simplifying or deleting orchestration, not by adding another guard or recovery layer.

## Release-surface rules

- Keep `README.md` user-facing: installation, configuration, usage, compatibility, and safety. Put build, test, FAT, CI, and release procedures under `docs/` or `scripts/`.
- Use `KVM Switcher` for display text, `KvmSwitcher` for Windows identifiers, and `kvm-switcher` for Unix/Debian identifiers. Use `MSI` only for factual hardware, vendor, or model compatibility wording, never for product, package, or artifact branding.
- Before final artifact generation, freeze the version, package/artifact filenames, and user-facing copy. Any later source or embedded-resource change invalidates built artifacts and requires applicable verification gates to rerun.
