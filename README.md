# TenneCRM, in Koka

A gym CRM for Windows, rewritten from Rust/egui into [Koka](https://koka-lang.github.io/koka/doc/book.html)
with a hand-written Win32 platform layer and software renderer. No GUI
framework: the window, the backbuffer, the glyph blitting, the immediate-mode
widget protocol and the layout are all in this repository.

The Rust original is at `../../tmp/tenne_rust` and is the reference for
behaviour. An existing `tenne.db` written by that build opens here unchanged —
that is a hard requirement, and `verify.sh` checks it every run.

## Build and run

```sh
./build.sh          # debug build -> tenne.exe
./tenne.exe         # opens tenne.db beside the exe

RELEASE=1 OUT=tenne-rel.exe ./build.sh    # the shippable build
```

**Ship the release build, never the default one.** Koka hardcodes the debug CRT
(`-MDd`), which links `ucrtbased.dll` — not redistributable, so the default exe
will not start on a machine without Visual Studio. `verify.sh` greps the release
exe's imports so this cannot regress silently.

Tests deliberately stay on the debug build: its allocator is what catches the
Koka miscompilations described below.

## Verify

```sh
./verify.sh         # ~14 minutes from cold, everything
```

One command, and it is the contract. It runs the TLA+ model checker, every test
suite, a conformance walk, a 984-frame soak, and a CRT dependency check. A suite
must print `ALL PASS` **and** exit 0 **and** leave no allocator complaint on
stderr — the third condition is not redundant.

The UI suites drive **clicks**, not repository calls. That distinction has
already mattered once: the sale-correction cases called `repo2/update-sale`
directly and stayed green for an iteration while the dialog they were supposed
to cover was calling `record-sale` instead, writing a second sale and taking the
stock twice.

Requires `koka`, `java` and `clang-cl` on PATH.

## Layout

| Path | What |
|---|---|
| `src/win32-inline.c`, `src/win32.kk` | platform layer: window, message pump, DIB backbuffer, glyph atlas, files |
| `src/ui.kk` | the immediate-mode core — hot/active/focus. Read `docs/tla/README-ImmediateMode.md` first |
| `src/widgets.kk`, `src/textfield.kk` | drawn widgets; text editing split out because it has real behaviour. Arrows, Home/End and their Shift forms, Ctrl+A/C/X/V, and a field that scrolls to keep the caret visible. The rule is a pure function of `(edit, key, clipboard)`; only `apply-key-io` touches the machine |
| `src/sql-inline.c`, `src/sql.kk` | SQLite via the amalgamation |
| `src/repo.kk`, `src/repo2.kk` | the data layer. Maps to `docs/tla/README.md`'s action table |
| `src/view-*.kk`, `src/dlg-*.kk` | the six views and their dialogs |
| `src/dialogs.kk` | the one dialog dispatch. Add a dialog here and the soak sweeps it |
| `src/license.kk`, `src/license-inline.c` | offline licence keys, and the cap an unlicensed copy runs under |
| `mintkey.sh` | mints one key per sale. Needs `license-private.pem` |
| `src/*test.kk`, `src/*shot.kk` | test suites; `*shot` ones render offscreen to BMP |
| `docs/tla/` | three specs, their broken variants, and READMEs explaining both |

## The specs are not decoration

`docs/tla/ImmediateMode.tla` models the frame loop and widget protocol. It found
two bugs before the code existed, both needing two events inside one frame —
neither would have been found by testing:

- press on empty space, drag onto a button, release, and the button fires;
- type, then click into another field, and the character lands in the field you
  clicked.

`TenneCRM.tla` and `Durability.tla` came from the Rust build and model the
domain, so they carry over unchanged. `src/conform.kk` walks their actions over
a real database and re-checks every invariant after every action;
`src/conformbroken.kk` runs the same walk with a guard removed and is **required
to fail**, so the conformance suite cannot go vacuous.

## ⚠ Koka 3.2.3 miscompiles several ordinary shapes

Six distinct silent miscompilations were hit during this port, all producing
memory corruption with a clean exit code. The full list with diagnoses is in
`.ralph/koka-tenne.md`. The short version:

- **`match` arms that consume a value from outside the match double-free.** Use
  `if`/`elif`. This was live in `main.kk`'s view dispatch for a full iteration.
- **Tuple destructuring** (`val (a,b) = ...`) in such a function does it too.
- **Pattern guards** (`Pat | cond ->`) likewise.
- **Reading the same field twice** in one function can corrupt.
- **A `ref` crossing a function boundary** emits undeclared evidence variables.
- **Repository calls inside a row-drawing function** drag in a `div` effect that
  then miscompiles. Compute strings in one pass before the loop.

If something segfaults or mimalloc complains, it is almost certainly one of
these, not your logic. `sql/unbuffer()` exists so a crash still tells you how far
it got.

## Licensing

Buy once, activate offline, no account and no server — a gym with no internet
is a gym that still works. A key is base32 of a small payload (licensee name
and purchase date) plus an ECDSA P-256 signature over it, checked through
Windows' own CNG, so the exe carries **only the public key** and a keygen
cannot be built from the binary.

```sh
./mintkey.sh "Iron Temple Gym"              # one key, paste it into the email
./mintkey.sh "Iron Temple Gym" 2026-09-21   # backdated to the purchase date
```

`license-private.pem` is the only thing in the world that can mint a key this
build accepts. **Keep it off the build machine and out of any repository.**
Leak it and anyone can issue licences; lose it and every future key needs a new
public key compiled in, which invalidates every key already sold.

Unlicensed, everything runs — backups, CSV, reports, the whole month — but the
roster, the shelf and the till each stop at ten (`free-members`,
`free-products`, `free-sales`). The cap is on *adding* only: an existing
database always opens, whatever its size, because locking an owner out of their
own member list reads as data loss, and an existing sale stays correctable
because a mis-rung sale nobody can fix is worse than an unlicensed one.

Every door that creates one of the three asks the gate — the dialog the user
clicks *and* the CSV importer — since a cap the spreadsheet walks through is
not a cap:

```sh
grep -rn "can-add-" src/dlg-*.kk src/csv.kk
```

What this deliberately does **not** do is stop a key, or the program, being
shared. Offline activation cannot: there is nothing to count seats against. So
the licensee's name is signed into the key and shown in the sidebar for as long
as the app is open — a passed-around copy spends all day with somebody else's
name on it. Node-locking would need a two-step activation and a support burden
on every reinstall; a licence server would cost the offline promise outright.
Both were considered and refused.

## The gap this port keeps having

Five times now, a repository function has been implemented, tested at the
repository level, and reachable from **no click** — so the user could create a
record and never correct or remove it. Every one was found by reading the Rust
`src/ui/` rather than by the plan, which claimed completeness each time.

The query that finds them:

```sh
grep -n "^pub fun \(insert\|update\|delete\)" src/repo.kk src/repo2.kk
grep -rn "<that function>" src/view-*.kk src/dlg-*.kk
```

No caller under `src/view-*.kk` or `src/dlg-*.kk` means a feature nobody can
reach. Run it before believing a feature is done.

## Where the work is tracked

`.ralph/koka-tenne.md` is the real engineering log: the full checklist, every
gotcha with its diagnosis, and a reflection at iterations 8, 9 and 13. Start
there.
