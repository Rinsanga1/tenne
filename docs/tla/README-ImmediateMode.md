# ImmediateMode — the frame loop and the widget protocol

`TenneCRM.tla` and `Durability.tla` model the domain and the file underneath
it. Both were written against the Rust build, both still apply: they model
*what the application means*, not what it is written in, and the Koka port
must satisfy them unchanged.

This module models the thing the port actually invents. The Rust build got its
frame loop and its hit-testing from egui. The Koka build writes them, so they
have to be designed rather than assumed.

An immediate-mode GUI keeps almost no state between frames. What little it does
keep is two words — which widget the cursor is over (`hot`), and which widget
captured the press and is owed the release (`active`) — and every button,
row, dropdown and text field in the application runs through them.

| File | What it is |
|---|---|
| `ImmediateMode.tla` | The design. One module; the constant `Bug` selects which guard to remove. |
| `ImmediateMode.cfg` | The model: 2 widgets, 2 presses, 2 keys, 4 events latched between frames. `Bug = "None"`. |
| `ImmediateModeFireAnywhere.cfg` | The release stops checking where it landed. |
| `ImmediateModeKeepVanishedCapture.cfg` | The frame stops dropping a capture whose widget is gone. |
| `ImmediateModeKeepVanishedFocus.cfg` | The frame stops dropping a focus whose widget is gone. |
| `ImmediateModeMouseThenKeys.cfg` | The frame handles all mouse events, then all key events. |

## Running it

```sh
cd docs/tla

# the design — passes
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto \
  -config ImmediateMode.cfg ImmediateMode.tla

# the two guards removed, one at a time — each fails, which is how we know
# the invariants are not vacuously true
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto \
  -config ImmediateModeFireAnywhere.cfg ImmediateMode.tla
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto \
  -config ImmediateModeKeepVanishedCapture.cfg ImmediateMode.tla
```

## The state, and where it will live in the code

| Variable | Meaning | Implementation |
|---|---|---|
| `mouse` | the physical button | `WM_LBUTTONDOWN` / `WM_LBUTTONUP` in the window procedure, `src/win32-inline.c` |
| `over` | the widget under the cursor — **ground truth**, not the UI's opinion | never stored; it is the world the invariants check the UI against |
| `pending` | input latched since the last frame, each event carrying the position it happened at | the event ring the window procedure appends to, drained once per frame by `win32/poll-events` |
| `ui.hot` | the widget the cursor is over, as the UI believes | `Ui/hot : widget-id`, recomputed every frame |
| `ui.active` | the widget that captured the press | `Ui/active : widget-id` |
| `ui.focus` | the widget the keyboard is talking to | `Ui/focus : widget-id`; `ui/typed-chars` and `ui/typed-keys` route to it |
| `ui.present` | the widgets this frame built | implicit — the set of ids passed to a widget call during `frame-begin`..`frame-end`. Must be tracked explicitly, or `ActiveIsPresent` cannot be enforced. |
| `history`, `fires` | ghosts | nothing. They exist so the invariants can compare what the UI decided against what the user did. |

Deliberately absent, because no invariant mentions them: pixels, rectangles,
layout, text, scroll offsets, widget kinds, the keyboard. A widget here is an
identity and nothing else — which is exactly the abstraction the hot/active
protocol operates on.

## Actions → functions

| Action | Code |
|---|---|
| `MoveTo` | `WM_MOUSEMOVE` |
| `Press` / `Release` | `WM_LBUTTONDOWN` / `WM_LBUTTONUP`, appended to the event ring |
| `Frame` | one turn of the main loop in `src/main.kk`: drain events, build widgets, blit |
| `Apply` | `ui/apply-event` — the whole protocol, ~20 lines |

`Frame` is the only action the system takes on its own, so it carries the only
fairness condition (`WF_vars(Frame)`). Every other action is a hand on a mouse,
and no amount of weak fairness makes a person click.

## The invariants, in plain English

| Invariant | What it means on screen |
|---|---|
| `TypeOK` | every variable holds the kind of value it should |
| `HotIsPresent` | nothing is highlighted that isn't drawn — no stale lit row in the sidebar after the view changes |
| `ActiveIsPresent` | nothing is mid-interaction that isn't drawn — navigating away while holding the button drops the capture |
| `FocusIsPresent` | the keyboard never talks to a field that isn't drawn — close a dialog and its field stops receiving keystrokes |
| `NoPhantomFire` | a button fires only if you both pressed *and* released on it; drag off and let go and nothing happens |
| `FiresAreDistinct` | no press is honoured twice, under any interleaving of frames |
| `ClicksNotInvented` | one press, at most one fire — never a payment recorded twice |
| `KeysGoWhereAimed` | a keystroke never lands in a field that was only clicked into *afterwards* |
| `KeysNotInvented` | nothing typed is silently dropped or duplicated |
| `InputDrains` (liveness) | input never sits in the latch forever; the queue may fill only because it is guaranteed to drain |

## Result — the design

```
Model checking completed. No error has been found.
3812143 states generated, 597594 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 17.
```

Eight invariants and the liveness property hold across 597,594 distinct states.

## The bug the spec found before any code existed

The first draft latched events as bare kinds — `Down`, `Up` — and hit-tested
them at drain time against wherever the cursor had ended up. TLC killed it at
depth 5:

```
State 2: <Press>    over = NilW   pending = <<"Down">>
State 3: <MoveTo>   over = w1
State 4: <Release>  over = w1     pending = <<"Down", "Up">>
State 5: <Frame>    fires w1
```

**The story.** You press the mouse on empty space — on the padding beside a
button, say, or on a row you decided against. Still holding it, you drag onto
a button. You let go. The button fires. You never pressed it.

It happens because the press was *applied* at a position the cursor only
reached afterwards. Between the press and the frame that consumes it, the
mouse moved, and a frame that asks "where is the cursor now?" gets the wrong
answer for an event that happened in the past.

**The fix, and it is a constraint on the platform layer.** Every latched event
carries the position it happened at. Win32 already puts it in the `lParam` of
`WM_LBUTTONDOWN` and `WM_LBUTTONUP`, precisely for this reason. Calling
`GetCursorPos` when draining the queue is the bug.

This is the return on writing the spec first: a Handmade-Hero-style input
layer written the obvious way has this bug, and it would have presented as
"buttons sometimes click themselves" — the kind of thing that survives a long
time because it needs a drag to reproduce.

## Result — the guards removed

### 1. `FireAnywhere` — the release stops checking where it landed

`NoPhantomFire` violated in six states:

```
State 3: <Press>    over = w1   history = <<[Down, at w1, id 1]>>
State 4: <MoveTo>   over = w2
State 5: <Release>  over = w2   history = <<[Down, at w1, id 1], [Up, at w2, id 1]>>
State 6: <Frame>    fires = <<[id 1, w w1]>>
```

**The story.** You press *Delete member* and immediately think better of it. You
do what everyone does: keep the button held, drag the pointer away, and let go
somewhere safe. The member is deleted anyway. The press bound to the button
correctly; it was the release that stopped caring, so "button was down, now
it's up, therefore it was clicked" destroys the one gesture every GUI since the
Macintosh has offered for calling a click off.

### 2. `KeepVanishedCapture` — a capture outlives the widget

`ActiveIsPresent` violated in seven states:

```
State 3: <Press>  over = w2, captured by w2
State 6: <Frame>  ui = [hot |-> NilW, active |-> w2, present |-> {w2}]
State 7: <Frame>  ui = [hot |-> NilW, active |-> w2, present |-> {}]
```

**The story.** You press something and, still holding, the view changes under
you — a confirm dialog closes, a modal opens, a row is deleted out from under
the cursor. The widget is gone but the UI still has its id marked active. The
next widget to take that id inherits a press the user never made on it, and
fires on a release they never aimed at it.

This is the failure mode that immediate-mode GUIs are notorious for, and the
reason `ui.present` must be tracked at all: without knowing which widgets this
frame actually built, there is no way to notice that the captured one is no
longer among them.

### 3. `KeepVanishedFocus` — the keyboard talks to a field that is gone

`FocusIsPresent` violated. **The story.** You are editing a member's name and
the dialog closes — you pressed Escape, or the row was deleted under you. The
field is no longer drawn but the UI still has its id as the focus. Every
keystroke after that is typed into a widget nobody can see; the next frame that
reuses the id receives them.

### 4. `MouseThenKeys` — a character lands in the wrong field

`KeysGoWhereAimed` violated in five states:

```
State 3: <TypeKey>  history = <<[Key, seq 1]>>
State 4: <Press>    history = <<[Key, seq 1], [Down, at w2, seq 2]>>
State 5: <Frame>    typed   = <<[seq 1, to w2]>>
```

**The story.** You finish typing a member's name and click into the phone box.
Both land between the same two frames — which is ordinary at 60fps, and certain
when a database query has just dropped the frame rate. A frame that handles all
the mouse events and then all the key events settles the focus on the phone box
*first*, and then posts the last characters of the name into it.

That two-pass shape is what input code naturally falls into: one loop for the
mouse, one for the keyboard. The fix is to treat the latched events as a single
ordered stream.

**And a constraint on the implementation.** In the code, widgets each scan the
event list — they must, since only a widget knows its own rectangle. That makes
a mid-batch focus change deliver the keystroke *twice*, once by the field losing
focus and once by the field gaining it. So `ui/frame-begin` resolves the
keyboard centrally and holds back any keystroke that follows a press in the same
batch, delivering it on the next frame once the focus has settled. Same field,
one frame later, and only in the rare case where a click and a keystroke land
between the same two frames.

## A note on what ground truth means here

The first draft of `KeysGoWhereAimed` tagged each keystroke with the widget that
was *visibly* focused when it was pressed, and asserted the delivery matched.
TLC rejected it at depth 6, and was right to: click into a field and type before
the next frame renders, and nothing is visibly focused yet — but the character
plainly belongs to the field you just clicked.

The invariant that survives is about **order**, not about a snapshot: a key may
only land in a field that was clicked into *earlier in the event stream*. That
is checkable against the ghost history without the UI being able to agree with
itself, and it is exactly the property the two-pass bug breaks.

## What this model does not cover

- **Tab order, and Enter committing a field.** Focus is modelled as something
  the mouse moves; a keyboard-driven focus change is a further action and a
  further invariant.
- **Text content and the caret.** The spec models where a keystroke *goes*, not
  what it does when it arrives. Insertion, deletion and selection are ordinary
  sequential code with no concurrency in them.
- **Widget identity itself.** The spec assumes ids are stable across frames and
  unique within one. That assumption is the single largest source of real
  immediate-mode bugs, and it is a property of the *id-generation scheme* —
  worth its own model once that scheme exists.
- **Layout, clipping and scrolling.** A widget scrolled out of view is simply
  not in `present`, which the spec already handles. How it comes to be absent
  is a rendering question, not a protocol one.
- **Double-clicks, drag thresholds, and the mouse wheel.** Nothing here
  forbids them; they are additional event kinds and would extend `Apply`.
