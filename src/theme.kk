// The three palettes from the Rust build, unchanged. Colours are 0xAARRGGBB.
//
// Money/status colours stay fixed across every theme: money is money, and a
// figure that means "owed" must not change meaning when the user switches to
// light mode.
module theme

pub val accent       = 0xFF8B5CF6   // mdsfrontend brand violet
pub val tenne-accent = 0xFFCD5700   // the heraldic burnt-orange the app is named after
pub val positive     = 0xFF22C55E
pub val negative     = 0xFFEF4444
pub val warning      = 0xFFF59E0B

pub struct palette
  dark          : bool
  main          : int
  sidebar       : int
  card          : int
  faint         : int
  border        : int
  border-strong : int
  text          : int
  text-muted    : int
  btn           : int
  btn-hover     : int
  btn-active    : int
  nav-selected  : int
  accent        : int

// Light counterpart to the mdsfrontend dark design, built from its gray ramp.
pub val light = Palette(
  False,
  0xFFFFFFFF, 0xFFF9FAFB, 0xFFFFFFFF, 0xFFF3F4F6,
  0xFFE5E7EB, 0xFFD1D5DB,
  0xFF0B1120, 0xFF6B7280,
  0xFFF3F4F6, 0xFFE5E7EB, 0xFFD1D5DB,
  0xFFF3F4F6, accent)

// mdsfrontend dark tokens.
pub val dark = Palette(
  True,
  0xFF0A0A0A, 0xFF0A0A0A, 0xFF171717, 0xFF141414,
  0xFF404040, 0xFF737373,
  0xFFFAFAFA, 0xFFA3A3A3,
  0xFF161616, 0xFF232323, 0xFF3B3B3B,
  0xFF171717, accent)

// A warm dark theme: neutral surfaces tinted toward brown, violet swapped for
// tenne burnt-orange.
pub val tenne = Palette(
  True,
  0xFF120D0A, 0xFF120D0A, 0xFF1F1712, 0xFF1A130F,
  0xFF4A3A2E, 0xFF7D624E,
  0xFFFAF5F0, 0xFFB09E90,
  0xFF1F1712, 0xFF2E221A, 0xFF423125,
  0xFF1F1712, tenne-accent)

// Matches Mode::from_str: anything unrecognised is dark, as it was.
pub fun palette-of( name : string ) : palette
  val n = name.to-lower
  if n == "light" then light
  elif n == "tenne" then tenne
  else dark

pub fun palette-name( p : palette ) : string
  if p.accent == tenne-accent then "tenne"
  elif p.dark then "dark"
  else "light"
