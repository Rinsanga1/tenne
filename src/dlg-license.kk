// Activation. One dialog, one field, no account and no network: the key
// carries its own proof, so this runs on a gym PC that has never been online.
//
// The key is long because it holds a signature, and a signature is what stops
// anyone minting their own. Long means pasted, so Paste is a button here
// rather than a keystroke the user has to know about.
module dlg-license

import win32
import ui
import theme
import widgets
import license
import app

pub fun dialog( r : ref<global,ui/ui>, s : app/state, f : app/licence-form ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val current = f.key
  val err = f.error
  val box = widgets/modal-frame(r, p, 540, 260, "Activate TenneCRM")
  var g := f

  val row = widgets/field-row(r, p, box, 0, "Licence key")
  val fw = row.w - 100
  g := g(key = widgets/text-field(r, p, Rect(row.x, row.y, fw, row.h), current,
                                  ui/wid("lic:key"), "paste your key here"))
  if widgets/button(r, p, Rect(row.x + fw + 10, row.y, 90, 30), "Paste",
                    ui/wid("lic:paste")) then
    g := g(key = win32/clipboard(), error = "")

  // A key is longer than the box, so only its head is ever on screen. The
  // count is the only way to tell a whole key from half of one that came off
  // the clipboard truncated.
  val typed = g.key.trim
  widgets/label((!r).font-small, row.x, row.y + 40,
                (if typed == "" then "It was emailed to you when you bought TenneCRM."
                 else typed.count.show ++ " characters"), p.text-muted)

  if err != "" then
    widgets/label((!r).font-small, box.x + 20, box.y + box.h - 84, err, theme/negative)
  elif s.licensee != "" then
    widgets/label((!r).font-small, box.x + 20, box.y + box.h - 84,
                  "This copy is licensed to " ++ s.licensee ++ ".", theme/positive)
  else
    widgets/label((!r).font-small, box.x + 20, box.y + box.h - 84,
                  "Unlicensed, this copy stops at " ++ license/free-members.show ++
                  " members. Everything else works.", p.text-muted)

  val (go, cancel) = widgets/modal-buttons(r, p, box, "Activate", "lic", typed != "")
  if cancel || ui/escape-pressed(r) then s(licence = Nothing)
  elif !go then s(licence = Just(g))
  else
    val who = license/activate(typed)
    if who == "" then
      s(licence = Just(g(error = "That key was not issued for TenneCRM. Check the whole key was copied.")))
    else
      // The licensee is carried in state from here on; nothing re-verifies
      // per frame, and nothing can change it without another activation.
      s(licence = Nothing, licensee = who, notice = "Licensed to " ++ who)
