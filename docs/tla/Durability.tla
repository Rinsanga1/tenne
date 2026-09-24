---------------------------- MODULE Durability -----------------------------
(***************************************************************************)
(* How a TenneCRM user loses data the app already told them was saved.     *)
(*                                                                         *)
(* TenneCRM.tla models which records exist inside one open database. This  *)
(* module models the file underneath it: tenne.db, its -wal sidecar, the   *)
(* backups/ folder, and the restore that spans a restart. Every loss       *)
(* modelled here happens with the app behaving exactly as written - no     *)
(* disk failure, no corruption, no user deleting anything.                 *)
(*                                                                         *)
(* Fixed = FALSE is the code before the fixes. Fixed = TRUE is the design, *)
(* now shipped: snapshot the database through SQLite rather than copying   *)
(* the file, and remove the stale -wal before reopening a restored one.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Records,  \* abstract saved records: a member, a payment, a sale
    Keep,     \* backup::KEEP_LAST - how many backups the ring holds
    None,     \* model value: no restore promise outstanding
    Fixed     \* TRUE = the shipped design, FALSE = the code before the fixes

VARIABLES
    db,         \* records that live in tenne.db itself
    wal,        \* records committed but living only in tenne.db-wal
    running,    \* the app has the database open
    backups,    \* backups/, oldest first
    pending,    \* index of a queued restore; 0 = none
    claim,      \* what the app promised a reopen would bring back
    saved,      \* ghost: every record the app ever confirmed as saved
    discarded   \* ghost: records the user knowingly left behind by restoring

vars == <<db, wal, running, backups, pending, claim, saved, discarded>>

\* A file in backups/. `captured` is what the bytes on disk actually contain;
\* `truth` is what the app held at the moment it wrote them. They are equal in
\* any honest backup, and the whole point of the model is that they can differ.
Snapshot == [captured : SUBSET Records, truth : SUBSET Records]

TypeOK ==
    /\ db \subseteq Records
    /\ wal \subseteq Records
    /\ running \in BOOLEAN
    /\ backups \in Seq(Snapshot)
    /\ Len(backups) =< Keep
    /\ pending \in 0..Keep
    /\ claim \in {None} \cup SUBSET Records
    /\ saved \subseteq Records
    /\ discarded \subseteq Records

-----------------------------------------------------------------------------
\* Helpers

\* What the app shows you. A reader sees the main file with the -wal replayed
\* over it, so committed-but-uncheckpointed records are visible in the app
\* while being absent from tenne.db on disk.
Visible == db \cup wal

InBackups == UNION { backups[i].captured : i \in 1..Len(backups) }

\* backup::prune - the ring keeps the newest `Keep` files and deletes the rest.
Push(s, e) == IF Len(s) < Keep THEN Append(s, e) ELSE Append(SubSeq(s, 2, Len(s)), e)

-----------------------------------------------------------------------------
\* Actions

\* Saving a record. In WAL mode the commit lands in the -wal sidecar; tenne.db
\* itself is untouched until a checkpoint. Carrying on working discharges any
\* outstanding restore promise.
Write(r) ==
    /\ running
    /\ r \notin Visible
    /\ wal' = wal \cup {r}
    /\ saved' = saved \cup {r}
    /\ claim' = None
    /\ UNCHANGED <<db, running, backups, pending, discarded>>

\* PRAGMA wal_checkpoint(FULL) - Repository::checkpoint.
Checkpoint ==
    /\ running
    /\ wal # {}
    /\ db' = db \cup wal
    /\ wal' = {}
    /\ UNCHANGED <<running, backups, pending, claim, saved, discarded>>

\* Settings -> "Back up now". The shipped code calls checkpoint, ignores
\* whether it worked, then fs::copy's tenne.db alone - so when the checkpoint
\* does not happen the copy is a file that looks like a backup and holds only
\* what had already reached the main file. The fix takes the snapshot through
\* SQLite (VACUUM INTO), which is consistent whatever the -wal holds.
TakeBackup ==
    /\ running
    /\ IF Fixed
         THEN /\ backups' = Push(backups, [captured |-> Visible, truth |-> Visible])
              /\ UNCHANGED <<db, wal>>
         ELSE \/ /\ backups' = Push(backups, [captured |-> Visible, truth |-> Visible])
                 /\ db' = db \cup wal
                 /\ wal' = {}
              \/ /\ backups' = Push(backups, [captured |-> db, truth |-> Visible])
                 /\ UNCHANGED <<db, wal>>
    /\ UNCHANGED <<running, pending, claim, saved, discarded>>

\* Closing the window. App::on_exit checkpoints and then copies, throttled to
\* one backup every six hours - so closing the app usually writes nothing.
\* Dropping the connection checkpoints and removes the -wal.
CleanExit ==
    /\ running
    /\ running' = FALSE
    /\ db' = db \cup wal
    /\ wal' = {}
    /\ \/ backups' = Push(backups, [captured |-> Visible, truth |-> Visible])
       \/ backups' = backups
    /\ UNCHANGED <<pending, claim, saved, discarded>>

\* Task Manager, a power cut, a forced Windows restart. No checkpoint runs and
\* the -wal file stays on disk holding committed records.
Crash ==
    /\ running
    /\ running' = FALSE
    /\ UNCHANGED <<db, wal, backups, pending, claim, saved, discarded>>

\* Settings -> "Restore from file...". The app cannot swap the database out
\* from under itself, so it writes tenne.db.pending-restore and tells you to
\* reopen.
QueueRestore(i) ==
    /\ running
    /\ i \in 1..Len(backups)
    /\ pending' = i
    /\ UNCHANGED <<db, wal, running, backups, claim, saved, discarded>>

\* Launching the app. App::new applies a pending restore by copying the backup
\* over tenne.db and touching nothing else, then opens the database - at which
\* point any -wal left by a crash is replayed on top of the file just restored.
\* The fix deletes the -wal and -shm alongside the copy.
\*
\* What the user means by restoring is "go back to what that backup held", so
\* what they knowingly give up is measured against the backup's truth, not
\* against the bytes that happened to be in the file.
Open ==
    /\ ~running
    /\ running' = TRUE
    /\ pending' = 0
    /\ IF pending = 0
         THEN /\ db' = db \cup wal
              /\ wal' = {}
              /\ UNCHANGED <<claim, discarded>>
         ELSE /\ claim' = backups[pending].captured
              /\ discarded' = discarded \cup (Visible \ backups[pending].truth)
              /\ db' = IF Fixed THEN backups[pending].captured
                                ELSE backups[pending].captured \cup wal
              /\ wal' = {}
    /\ UNCHANGED <<backups, saved>>

Init ==
    /\ db = {}
    /\ wal = {}
    /\ running = FALSE
    /\ backups = << >>
    /\ pending = 0
    /\ claim = None
    /\ saved = {}
    /\ discarded = {}

Next ==
    \/ Open
    \/ Crash
    \/ CleanExit
    \/ Checkpoint
    \/ TakeBackup
    \/ \E r \in Records : Write(r)
    \/ \E i \in 1..Keep : QueueRestore(i)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Invariants
(***************************************************************************)
(* No fairness, and so no liveness property. Every action in this module is *)
(* a person clicking something, a process being killed, or the OS. Nothing  *)
(* here is guaranteed to happen, and a spec should not pretend otherwise -  *)
(* weak fairness on Open would amount to assuming the gym owner reopens the *)
(* app, which is exactly the assumption that loses the data.                *)
(***************************************************************************)

\* Every file in backups/ holds what the app had when it wrote it.
BackupsAreHonest ==
    \A i \in 1..Len(backups) : backups[i].captured = backups[i].truth

\* When the app says "restore ready, close and reopen to finish", reopening
\* shows exactly the backup that was picked - not the data it was meant to
\* replace.
RestoreHonoured ==
    (running /\ claim # None) => Visible = claim

\* Nothing the app confirmed as saved is gone, unless the user asked for an
\* older backup and knowingly left it behind.
NothingLostSilently ==
    (saved \ discarded) \subseteq (Visible \cup InBackups)

=============================================================================
