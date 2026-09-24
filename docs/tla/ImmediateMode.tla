-------------------------- MODULE ImmediateMode --------------------------
(***************************************************************************)
(* The part of the Koka rewrite that has no counterpart in the Rust build:  *)
(* the frame loop and the immediate-mode widget protocol that replaces      *)
(* egui.                                                                    *)
(*                                                                          *)
(* An immediate-mode GUI keeps almost no state between frames -- that is     *)
(* the point of it. What little it does keep is exactly where the bugs      *)
(* live: which widget the cursor is over (`hot`), which widget captured the  *)
(* press and is owed the release (`active`), and which widget the keyboard  *)
(* is talking to (`focus`). Three words of state, and every button, row,    *)
(* dropdown and text field in the application runs through them.            *)
(*                                                                          *)
(* THE STATE                                                                *)
(*                                                                          *)
(*   mouse    the physical button, "Up" or "Down". The user changes it.     *)
(*   over     the widget physically under the cursor, or Nil for empty      *)
(*            space. The user changes it. This is ground truth about the    *)
(*            world, NOT the UI's opinion -- the invariants cross-check the  *)
(*            UI's bookkeeping against it, which is the only reason they    *)
(*            have any teeth.                                               *)
(*   pending  input the platform layer has latched since the last frame.    *)
(*            A queue, because the user can act faster than we render, and  *)
(*            an event that falls between two frames must still be          *)
(*            delivered. Each event carries the context it happened in --    *)
(*            see Event, below.                                             *)
(*   ui       the words the UI keeps across frames: hot, active, focus, and *)
(*            present -- the set of widgets this frame actually built.      *)
(*            `present` varies because navigating changes which widgets     *)
(*            exist at all.                                                 *)
(*                                                                          *)
(* Three ghosts, which nothing reads and no implementation will have. They  *)
(* exist so the invariants can compare what the UI decided against what the *)
(* user actually did:                                                       *)
(*                                                                          *)
(*   history  every mouse event ever latched, with the position it happened *)
(*            at and a serial pairing each press with its release.          *)
(*   fires    every widget activation the UI produced, tagged with the      *)
(*            serial of the press it claims to be honouring.                *)
(*   typed    every keystroke the UI delivered: where it went, and its      *)
(*            position in the true order of events.                         *)
(*                                                                          *)
(* Deliberately absent: pixels, layout, rectangles, text content, scroll    *)
(* offsets, widget kinds, the caret. No invariant here mentions them. A     *)
(* widget is an identity and nothing else, which is precisely the           *)
(* abstraction the protocol operates on.                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Widget,      \* the set of widget identities
    Nil,         \* "no widget"
    MaxPresses,  \* bound on how many times the user clicks, to keep it finite
    MaxKeys,     \* bound on how many keys the user types
    MaxEvents,   \* bound on input latched between two frames
    Bug          \* which guard to remove -- see BROKEN RUNS at the foot

ASSUME Nil \notin Widget

Slot == Widget \cup {Nil}

(***************************************************************************)
(* An event is a kind plus the context it happened in.                      *)
(*                                                                          *)
(* A mouse event carries `at`, the widget the cursor was over when it       *)
(* occurred, and `id`, a serial pairing a press with its release.           *)
(*                                                                          *)
(* Carrying the position is not a detail -- it is the whole correctness      *)
(* argument for latching input. TLC killed the first draft at depth 5 when  *)
(* events were bare kinds hit-tested at drain time against the cursor's     *)
(* current position: press on empty space, drag onto a button, release, and *)
(* the button fires, because the press was applied at a position the cursor *)
(* only reached afterwards. Win32 puts the position in the lParam of        *)
(* WM_LBUTTONDOWN/UP for exactly this reason; GetCursorPos at drain time is *)
(* the bug.                                                                 *)
(*                                                                          *)
(* Every event also carries `seq`, its position in the true order of        *)
(* events. That ordering is the whole content of the keyboard invariant.    *)
(*                                                                          *)
(* An earlier draft instead tagged each key with the widget that was        *)
(* *visibly* focused when it was pressed, and asserted the delivery matched *)
(* it. TLC rejected that at depth 6, correctly: click into a field and type *)
(* before the next frame renders, and nothing is visibly focused yet -- but  *)
(* the character obviously belongs to the field you just clicked. The       *)
(* honest property is about order, not about a snapshot.                    *)
(***************************************************************************)
Event == [kind : {"Down", "Up", "Key"},
          at   : Slot,
          seq  : Nat,
          id   : 1..MaxPresses]

VARIABLES mouse, over, pending, ui, history, fires, typed

vars == <<mouse, over, pending, ui, history, fires, typed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* HELPERS                                                                  *)
(***************************************************************************)

\* How many presses the user has made. The next press takes the next serial.
Presses == Cardinality({i \in 1..Len(history) : history[i].kind = "Down"})

Keys == Cardinality({i \in 1..Len(history) : history[i].kind = "Key"})

\* Where the mouse event with this kind and serial actually happened, per the
\* ghost history. Nil if no such event was ever latched.
Where(k, n) ==
    LET S == {i \in 1..Len(history) : history[i].kind = k /\ history[i].id = n}
    IN  IF S = {} THEN Nil ELSE history[CHOOSE i \in S : TRUE].at

-----------------------------------------------------------------------------
(***************************************************************************)
(* THE TYPE INVARIANT                                                       *)
(***************************************************************************)

TypeOK ==
    /\ mouse \in {"Up", "Down"}
    /\ over \in Slot
    /\ Len(pending) =< MaxEvents
    /\ \A i \in 1..Len(pending) : pending[i] \in Event
    /\ ui \in [hot : Slot, active : Slot, focus : Slot, present : SUBSET Widget]
    /\ \A i \in 1..Len(history) : history[i] \in Event
    /\ \A i \in 1..Len(fires) : fires[i] \in [w : Widget, id : 1..MaxPresses]
    /\ \A i \in 1..Len(typed) : /\ typed[i].to \in Slot
                                /\ typed[i].seq \in Nat

-----------------------------------------------------------------------------
(***************************************************************************)
(* THE INVARIANTS                                                           *)
(*                                                                          *)
(* Written before the actions, on purpose. These say what must never        *)
(* happen on screen, in words a person who does not read TLA+ can check.    *)
(***************************************************************************)

\* Nothing is ever highlighted that isn't on screen. A widget that stops
\* being drawn -- because the user navigated away -- must stop being hot the
\* same frame, or the sidebar keeps a stale row lit after the view changes.
HotIsPresent == ui.hot # Nil => ui.hot \in ui.present

\* Nothing is ever mid-interaction that isn't on screen. Hold the mouse down
\* on a button, navigate away, and the capture must be dropped. If it isn't,
\* whichever widget reuses that identity in the new view inherits a press the
\* user never made there -- and fires on a release they never aimed at it.
ActiveIsPresent == ui.active # Nil => ui.active \in ui.present

\* The keyboard never talks to a field that isn't on screen. Close a dialog
\* while its name field has focus and the focus must go with it, or the next
\* frame's keystrokes are typed into a widget nobody can see -- in this
\* application, silently editing a member who is no longer on screen.
FocusIsPresent == ui.focus # Nil => ui.focus \in ui.present

PressIdx(i) == {j \in 1..(i-1) : history[j].kind = "Down"}

\* A button fires only if the user both pressed AND released over it. Press a
\* button, drag off it, let go -- nothing happens; that is how a person
\* cancels a click they changed their mind about, and every GUI since the
\* Macintosh has honoured it.
\*
\* Checked against the ghost history -- where the press and release really
\* landed -- not against the UI's own `active`, so the UI cannot simply agree
\* with itself.
NoPhantomFire ==
    \A i \in 1..Len(fires) :
        /\ Where("Down", fires[i].id) = fires[i].w
        /\ Where("Up",   fires[i].id) = fires[i].w

\* One press, at most one fire. A click is never doubled -- which in this
\* application means a payment recorded twice, or a member deleted along with
\* the confirm dialog that asked about them.
ClicksNotInvented == Len(fires) =< Presses

\* No press is honoured twice, under any interleaving of frames.
FiresAreDistinct ==
    \A i, j \in 1..Len(fires) : fires[i].id = fires[j].id => i = j

\* A keystroke never lands in a field that was only clicked into *afterwards*.
\*
\* This is the keyboard's NoPhantomFire. A frame that handles all the mouse
\* events and then all the key events settles focus on the last field clicked
\* and posts every character there -- so typing a member's name, tabbing to the
\* phone box with the mouse, and typing the number, puts the name in the phone
\* field too. Draining the queue in one ordered pass is what prevents it.
\*
\* Stated over the ghost history rather than over the UI's own focus, so the
\* UI cannot simply agree with itself.
KeysGoWhereAimed ==
    \A i \in 1..Len(typed) :
        typed[i].to # Nil =>
            \E j \in 1..Len(history) :
                /\ history[j].kind = "Down"
                /\ history[j].at   = typed[i].to
                /\ history[j].seq  < typed[i].seq

\* Nothing the user types is silently dropped or duplicated.
KeysNotInvented == Len(typed) =< Keys

-----------------------------------------------------------------------------
(***************************************************************************)
(* HOW ONE LATCHED EVENT IS APPLIED                                         *)
(*                                                                          *)
(* Each event is interpreted against the widgets present this frame, using   *)
(* the context the event itself carries.                                    *)
(***************************************************************************)

Apply(s, e, p) ==
    LET h == IF e.at \in p THEN e.at ELSE Nil
    IN  IF e.kind = "Down"
        THEN \* A press binds to the widget it landed on, and only if nothing
             \* holds the capture already -- a second button going down
             \* mid-drag is ignored. It also moves the keyboard focus, which
             \* is how clicking into a field focuses it and clicking empty
             \* space lets it go.
             LET s1 == [s EXCEPT !.focus = h]
             IN  IF s.active = Nil /\ h # Nil
                 THEN [s1 EXCEPT !.active = h]
                 ELSE s1
        ELSE IF e.kind = "Up"
        THEN \* A release always ends the capture. It fires only if it landed
             \* on the widget that took the press.
             IF s.active # Nil
             THEN IF s.active = h \/ Bug = "FireAnywhere"
                  THEN [s EXCEPT !.active = Nil,
                                 !.fires  = Append(s.fires,
                                                   [w |-> s.active, id |-> e.id])]
                  ELSE [s EXCEPT !.active = Nil]
             ELSE s
        ELSE \* A keystroke goes to whatever has focus at this point in the
             \* stream -- which is why the stream must be drained in order.
             IF s.focus = Nil
             THEN s
             ELSE [s EXCEPT !.typed = Append(s.typed,
                                             [to |-> s.focus, seq |-> e.seq])]

RECURSIVE Drain(_, _, _)

Drain(s, evts, p) ==
    IF evts = <<>>
    THEN s
    ELSE Drain(Apply(s, Head(evts), p), Tail(evts), p)

\* Mouse events first, then keys. This is the shape you get from handling the
\* mouse in one pass and the keyboard in another, which is how most input code
\* is naturally written -- and it is wrong. See BROKEN RUNS.
TwoPass(s, evts, p) ==
    LET mice == SelectSeq(evts, LAMBDA e : e.kind # "Key")
        keys == SelectSeq(evts, LAMBDA e : e.kind = "Key")
    IN  Drain(Drain(s, mice, p), keys, p)

-----------------------------------------------------------------------------
(***************************************************************************)
(* INITIAL STATE                                                            *)
(***************************************************************************)

Init ==
    /\ mouse   = "Up"
    /\ over    = Nil
    /\ pending = <<>>
    /\ ui      = [hot |-> Nil, active |-> Nil, focus |-> Nil, present |-> {}]
    /\ history = <<>>
    /\ fires   = <<>>
    /\ typed   = <<>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* ACTIONS THE USER TAKES                                                   *)
(***************************************************************************)

\* The cursor moves. Freely, and at any time -- including to empty space, and
\* including onto a widget that this frame has not drawn.
MoveTo ==
    \E w \in Slot :
        /\ w # over
        /\ over' = w
        /\ UNCHANGED <<mouse, pending, ui, history, fires, typed>>

\* The button goes down. The platform latches it; the frame has not run yet
\* and knows nothing about it.
Press ==
    LET e == [kind |-> "Down", at |-> over,
              seq |-> Len(history) + 1, id |-> Presses + 1]
    IN  /\ mouse = "Up"
        /\ Presses < MaxPresses
        /\ Len(pending) < MaxEvents
        /\ mouse'   = "Down"
        /\ pending' = Append(pending, e)
        /\ history' = Append(history, e)
        /\ UNCHANGED <<over, ui, fires, typed>>

\* The button comes up, taking the serial of the press it ends. Press and
\* Release can both land between two frames -- that is the whole reason
\* `pending` is a queue and not a sampled level.
Release ==
    LET e == [kind |-> "Up", at |-> over,
              seq |-> Len(history) + 1, id |-> Presses]
    IN  /\ mouse = "Down"
        /\ Len(pending) < MaxEvents
        /\ mouse'   = "Up"
        /\ pending' = Append(pending, e)
        /\ history' = Append(history, e)
        /\ UNCHANGED <<over, ui, fires, typed>>

\* The user types. The key takes its place in the true order of events, which
\* is all the invariant needs to know about it.
TypeKey ==
    LET e == [kind |-> "Key", at |-> Nil,
              seq |-> Len(history) + 1, id |-> 1]
    IN  /\ Keys < MaxKeys
        /\ Len(pending) < MaxEvents
        /\ pending' = Append(pending, e)
        /\ history' = Append(history, e)
        /\ UNCHANGED <<mouse, over, ui, fires, typed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* THE ACTION THE SYSTEM TAKES                                              *)
(***************************************************************************)

\* One turn of the frame loop. Picks the widgets this frame builds (any set --
\* the user may have navigated), drops a capture or a focus whose widget is
\* gone, recomputes hot from scratch, then drains everything the platform
\* latched.
Frame ==
    \E p \in SUBSET Widget :
        LET a0 == IF Bug = "KeepVanishedCapture"
                  THEN ui.active
                  ELSE IF ui.active \in p THEN ui.active ELSE Nil
            f0 == IF Bug = "KeepVanishedFocus"
                  THEN ui.focus
                  ELSE IF ui.focus \in p THEN ui.focus ELSE Nil
            h  == IF over \in p THEN over ELSE Nil
            s0 == [active |-> a0, focus |-> f0, fires |-> fires, typed |-> typed]
            s  == IF Bug = "MouseThenKeys"
                  THEN TwoPass(s0, pending, p)
                  ELSE Drain(s0, pending, p)
        IN  /\ ui'      = [hot |-> h, active |-> s.active,
                           focus |-> s.focus, present |-> p]
            /\ fires'   = s.fires
            /\ typed'   = s.typed
            /\ pending' = <<>>
            /\ UNCHANGED <<mouse, over, history>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* THE SPEC                                                                 *)
(*                                                                          *)
(* Fairness on Frame alone. The render loop is the only thing here the      *)
(* program controls; every other action is a hand on a mouse or a keyboard, *)
(* and no fairness condition makes a person type.                           *)
(***************************************************************************)

Next == MoveTo \/ Press \/ Release \/ TypeKey \/ Frame

Spec == Init /\ [][Next]_vars /\ WF_vars(Frame)

\* Input never sits in the latch forever: whatever the user does, the next
\* frame consumes it. This is what makes the queue safe -- it is allowed to
\* fill only because it is guaranteed to drain.
InputDrains == (pending # <<>>) ~> (pending = <<>>)

-----------------------------------------------------------------------------
(***************************************************************************)
(* BROKEN RUNS                                                              *)
(*                                                                          *)
(* An invariant nothing can violate passes exactly as cleanly as a correct  *)
(* design. `Bug` removes one guard at a time so TLC has to earn the pass.   *)
(*                                                                          *)
(*   "None"                 the design. Passes.                             *)
(*                                                                          *)
(*   "FireAnywhere"         the release stops checking that it landed on    *)
(*                          the widget that took the press -- the naive     *)
(*                          "button was down, now it's up, so it was        *)
(*                          clicked". Violates NoPhantomFire.               *)
(*                                                                          *)
(*   "KeepVanishedCapture"  the frame stops dropping a capture whose widget *)
(*                          is no longer drawn. Violates ActiveIsPresent.   *)
(*                                                                          *)
(*   "KeepVanishedFocus"    the frame stops dropping a focus whose widget   *)
(*                          is no longer drawn. Violates FocusIsPresent.    *)
(*                                                                          *)
(*   "MouseThenKeys"        the frame handles all mouse events, then all    *)
(*                          key events -- the structure most input code     *)
(*                          falls into. Violates KeysGoWhereAimed.          *)
(*                                                                          *)
(* See README-ImmediateMode.md for the counterexamples told as stories.     *)
(***************************************************************************)

=============================================================================
