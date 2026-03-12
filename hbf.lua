-- hbf.lua
-- HARDER BETTER FASTER
-- Daft Punk Acid Bass · Roulette Grid
-- requires: Norns + Grid (any size, optimised for 16x8)
-- engine: PolyPerc (built-in)
--
-- CONTROLS
-- grid [1,1]  = PLAY
-- grid [1,2]  = STOP
-- grid rest   = roulette (shuffled at boot)
-- E1          = BPM
-- E2          = root note (C2–C4)
-- E3          = filter cutoff
-- K2          = play / stop toggle
-- K3          = randomise synth patch

engine.name = "PolyPerc"

local musicutil = require "musicutil"

--------------------------------------------------------------------------------
-- SCALES
--------------------------------------------------------------------------------

local SCALES = {
  acid       = {0,2,3,5,7,8,10},
  phrygian   = {0,1,3,5,7,8,10},
  dorian     = {0,2,3,5,7,9,10},
  pentatonic = {0,3,5,7,10},
  wholetone  = {0,2,4,6,8,10},
}
local SCALE_NAMES = {"acid","phrygian","dorian","pentatonic","wholetone"}

--------------------------------------------------------------------------------
-- CHORD VOICINGS  (scale-degree offsets added on top of base degree)
--------------------------------------------------------------------------------

local CHORDS = {
  root   = {0},
  power  = {0,7},
  minor  = {0,3,7},
  major  = {0,4,7},
  dim    = {0,3,6},
  sus4   = {0,5,10},
  octave = {0,12},
}
local CHORD_NAMES = {"root","power","minor","major","dim","sus4","octave"}

--------------------------------------------------------------------------------
-- ARP PATTERNS  (indices into scale)
--------------------------------------------------------------------------------

local PATTERNS = {
  {1,2,3,4},
  {1,3,2,4},
  {1,1,2,3},
  {1,2,1,3,1,4},
  {4,3,2,1},
  {1,1,1,2,3},
  {1,2,3,2},
  {1,3,1,4,2,4},
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local s = {
  playing      = false,
  bpm          = 128,
  root_midi    = 36,
  scale        = "acid",
  chord        = "root",
  pat_idx      = 1,
  step         = 1,
  octave_shift = 0,
  pitch_bend   = 0,
  gate         = 0.8,
  velocity     = 0.8,
  swing        = 0,
  chorus       = false,
  minimal      = false,
  distort      = false,
  stutter      = false,
  stutter_div  = 1,
  glide        = false,
  skip         = false,
  cascade      = false,
  vel_ramp     = 0,
  vel_ramp_step= 0,
  cutoff       = 2000,
  pw           = 0.5,
  rel          = 0.3,
}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function rnd(t)
  return t[math.random(#t)]
end

local function reset_fx()
  s.stutter      = false
  s.stutter_div  = 1
  s.chorus       = false
  s.minimal      = false
  s.distort      = false
  s.glide        = false
  s.skip         = false
  s.cascade      = false
  s.pitch_bend   = 0
  s.octave_shift = 0
  s.vel_ramp     = 0
  s.swing        = 0
  s.gate         = 0.8
  s.velocity     = 0.8
end

local function apply_patch()
  engine.cutoff(s.cutoff)
  engine.pw(s.pw)
  engine.release(s.rel)
end

local function randomise_patch()
  s.cutoff = rnd({400,800,1200,2000,3500,6000,8000})
  s.pw     = math.random() * 0.7 + 0.1
  s.rel    = rnd({0.05,0.1,0.2,0.4,0.7,1.2})
  apply_patch()
end

--------------------------------------------------------------------------------
-- AUDIO
--------------------------------------------------------------------------------

local prev_hz = 0

local function midi_to_hz(m)
  return 440.0 * (2.0 ^ ((m - 69.0) / 12.0))
end

local function scale_note(degree)
  local sc  = SCALES[s.scale]
  local len = #sc
  local oct = math.floor((degree - 1) / len)
  local idx = ((degree - 1) % len) + 1
  return s.root_midi + oct * 12 + sc[idx] + s.octave_shift * 12 + s.pitch_bend
end

local function play_note(midi, vel, dur)
  local hz = midi_to_hz(midi)
  if s.distort then
    hz = hz * (1.0 + (math.random() * 0.04 - 0.02))
  end
  local cut = s.chorus and clamp(s.cutoff * 1.5, 100, 8000) or s.cutoff
  engine.cutoff(cut)
  engine.gain(clamp(vel * (s.chorus and 1.3 or 1.0), 0, 1))
  engine.release(dur * 0.6)
  engine.pw(s.pw)
  if s.glide and prev_hz > 0 then
    local start_hz = prev_hz
    local steps    = 8
    clock.run(function()
      for i = 1, steps do
        local t = i / steps
        engine.hz(start_hz + (hz - start_hz) * t)
        clock.sleep(dur / steps)
      end
    end)
  else
    engine.hz(hz)
  end
  prev_hz = hz
end

--------------------------------------------------------------------------------
-- SEQUENCER
--------------------------------------------------------------------------------

local seq_id = nil

local function step_sec()
  local base = 60.0 / s.bpm / 4.0
  return base / (s.stutter and s.stutter_div or 1)
end

local function advance()
  if s.skip and math.random() < 0.4 then
    s.step = (s.step % 64) + 1
    return
  end

  local pat      = PATTERNS[s.pat_idx]
  local offsets  = CHORDS[s.chord]
  local base_deg = pat[((s.step - 1) % #pat) + 1]
  local dur      = step_sec() * s.gate

  -- velocity ramp
  local vel = s.velocity
  if s.vel_ramp ~= 0 then
    s.vel_ramp_step = s.vel_ramp_step + 1
    local t = clamp(s.vel_ramp_step / 16.0, 0, 1)
    vel = s.vel_ramp == 1 and (0.3 + t * 0.7) or (1.0 - t * 0.7)
    vel = clamp(vel, 0.1, 1.0)
  end

  if s.minimal then
    if s.step % 2 == 1 then
      play_note(scale_note(base_deg), vel, dur)
    end
  else
    local notes = {}
    for _, off in ipairs(offsets) do
      table.insert(notes, scale_note(base_deg + off))
    end

    if s.cascade and #notes > 1 then
      for i, n in ipairs(notes) do
        local delay = (i - 1) * dur * 0.15
        clock.run(function()
          clock.sleep(delay)
          play_note(n, vel, dur)
        end)
      end
    else
      for _, n in ipairs(notes) do
        play_note(n, vel, dur)
      end
      if s.chorus then
        clock.run(function()
          clock.sleep(0.012)
          play_note(notes[1], vel * 0.5, dur)
        end)
      end
    end
  end

  s.step = (s.step % 64) + 1
end

local function start_seq()
  if seq_id then clock.cancel(seq_id) end
  s.playing = true
  seq_id = clock.run(function()
    while true do
      advance()
      clock.sleep(step_sec())
    end
  end)
end

local function stop_seq()
  s.playing = false
  if seq_id then
    clock.cancel(seq_id)
    seq_id = nil
  end
  engine.hz(0)
end

--------------------------------------------------------------------------------
-- ACTION POOL  (shuffled onto 126 roulette keys at boot)
--------------------------------------------------------------------------------

local ACTION_POOL = {
  -- scales
  function() s.scale = "acid"       end,
  function() s.scale = "phrygian"   end,
  function() s.scale = "dorian"     end,
  function() s.scale = "pentatonic" end,
  function() s.scale = "wholetone"  end,
  -- chords
  function() s.chord = "root"   end,
  function() s.chord = "power"  end,
  function() s.chord = "minor"  end,
  function() s.chord = "major"  end,
  function() s.chord = "dim"    end,
  function() s.chord = "sus4"   end,
  function() s.chord = "octave" end,
  -- patterns
  function() s.pat_idx = 1 end,
  function() s.pat_idx = 2 end,
  function() s.pat_idx = 3 end,
  function() s.pat_idx = 4 end,
  function() s.pat_idx = 5 end,
  function() s.pat_idx = 6 end,
  function() s.pat_idx = 7 end,
  function() s.pat_idx = 8 end,
  function() s.pat_idx = math.random(#PATTERNS) end,
  -- octave
  function() s.octave_shift = clamp(s.octave_shift + 1, -2, 2) end,
  function() s.octave_shift = clamp(s.octave_shift - 1, -2, 2) end,
  function() s.octave_shift = 0 end,
  -- pitch bend
  function() s.pitch_bend = clamp(s.pitch_bend + 1, -7, 7) end,
  function() s.pitch_bend = clamp(s.pitch_bend - 1, -7, 7) end,
  function() s.pitch_bend = clamp(s.pitch_bend + 2, -7, 7) end,
  function() s.pitch_bend = clamp(s.pitch_bend - 2, -7, 7) end,
  function() s.pitch_bend = clamp(s.pitch_bend + 5, -7, 7) end,
  function() s.pitch_bend = clamp(s.pitch_bend - 5, -7, 7) end,
  function() s.pitch_bend = 0 end,
  -- bpm
  function() s.bpm = clamp(s.bpm + 10, 60, 200); if s.playing then start_seq() end end,
  function() s.bpm = clamp(s.bpm - 10, 60, 200); if s.playing then start_seq() end end,
  function() s.bpm = clamp(s.bpm + 20, 60, 200); if s.playing then start_seq() end end,
  function() s.bpm = clamp(s.bpm - 20, 60, 200); if s.playing then start_seq() end end,
  function() s.bpm = 120; if s.playing then start_seq() end end,
  function() s.bpm = 128; if s.playing then start_seq() end end,
  function() s.bpm = 140; if s.playing then start_seq() end end,
  function() s.bpm = 160; if s.playing then start_seq() end end,
  function() s.bpm = 174; if s.playing then start_seq() end end,
  function() s.bpm = math.random(100, 180); if s.playing then start_seq() end end,
  -- stutter
  function() s.stutter = true;  s.stutter_div = 2 end,
  function() s.stutter = true;  s.stutter_div = 4 end,
  function() s.stutter = true;  s.stutter_div = 8 end,
  function() s.stutter = false; s.stutter_div = 1 end,
  -- fx toggles
  function() s.chorus  = not s.chorus  end,
  function() s.minimal = not s.minimal end,
  function() s.distort = not s.distort end,
  function() s.glide   = not s.glide   end,
  function() s.skip    = not s.skip    end,
  function() s.cascade = not s.cascade end,
  -- gate
  function() s.gate = 0.1 end,
  function() s.gate = 0.5 end,
  function() s.gate = 0.8 end,
  function() s.gate = 1.0 end,
  -- velocity
  function() s.velocity = 0.3 end,
  function() s.velocity = 0.6 end,
  function() s.velocity = 1.0 end,
  function() s.vel_ramp = 1;  s.vel_ramp_step = 0 end,
  function() s.vel_ramp = -1; s.vel_ramp_step = 0 end,
  function() s.vel_ramp = 0 end,
  -- swing
  function() s.swing = 0  end,
  function() s.swing = 25 end,
  function() s.swing = 50 end,
  -- root
  function() s.root_midi = clamp(s.root_midi + 1,  24, 60) end,
  function() s.root_midi = clamp(s.root_midi - 1,  24, 60) end,
  function() s.root_midi = clamp(s.root_midi + 7,  24, 60) end,
  function() s.root_midi = clamp(s.root_midi - 7,  24, 60) end,
  function() s.root_midi = 36 end,
  -- filter direct
  function() s.cutoff = 400;  engine.cutoff(s.cutoff) end,
  function() s.cutoff = 1200; engine.cutoff(s.cutoff) end,
  function() s.cutoff = 3000; engine.cutoff(s.cutoff) end,
  function() s.cutoff = 8000; engine.cutoff(s.cutoff) end,
  -- patch randomise
  randomise_patch,
  -- COMBOS
  function() s.scale = "acid"; s.stutter = true; s.stutter_div = 4 end,
  function() s.octave_shift = clamp(s.octave_shift - 1, -2, 2); s.chord = "power" end,
  function() s.chorus = true; s.velocity = 1.0 end,
  function() s.scale = "phrygian"; s.glide = true end,
  function() s.distort = true; s.bpm = clamp(math.floor(s.bpm * 1.5), 60, 200); if s.playing then start_seq() end end,
  function() s.minimal = true; s.gate = 0.1 end,
  function() s.stutter = true; s.stutter_div = 4; s.pitch_bend = clamp(s.pitch_bend + 2, -7, 7) end,
  function() s.pat_idx = 5; s.chorus = true end,
  function() s.cascade = true; s.swing = 30 end,
  function() s.chord = "dim"; s.octave_shift = clamp(s.octave_shift - 1, -2, 2) end,
  function() s.minimal = true; s.pat_idx = 1 end,
  function()
    s.scale    = SCALE_NAMES[math.random(#SCALE_NAMES)]
    s.chord    = CHORD_NAMES[math.random(#CHORD_NAMES)]
    s.pat_idx  = math.random(#PATTERNS)
    s.bpm      = math.random(100, 170)
    s.octave_shift = math.random(-1, 1)
    s.pitch_bend   = math.random(-3, 3)
    s.stutter  = (math.random() > 0.6)
    s.stutter_div  = rnd({2, 4, 8})
    s.chorus   = (math.random() > 0.5)
    s.distort  = (math.random() > 0.6)
    randomise_patch()
    if s.playing then start_seq() end
  end,
  function() s.scale = "dorian"; s.chord = "power"; s.swing = 25 end,
  function() s.cutoff = 8000; engine.cutoff(s.cutoff); s.cascade = true end,
  function() s.octave_shift = clamp(s.octave_shift - 1, -2, 2); s.stutter = true; s.stutter_div = 4 end,
  function() s.scale = "wholetone"; s.chorus = true; s.bpm = clamp(s.bpm + 20, 60, 200); if s.playing then start_seq() end end,
  function() s.scale = "acid"; s.pat_idx = 5; s.stutter = true; s.stutter_div = 4 end,
  function() s.skip = true; s.scale = "phrygian" end,
  reset_fx,
  function() s.glide = true; s.distort = true end,
  function() s.scale = "pentatonic"; s.bpm = clamp(math.floor(s.bpm * 1.5), 60, 200); if s.playing then start_seq() end end,
  function() s.chord = "sus4"; s.cascade = true end,
  function() s.stutter = true; s.stutter_div = 8; s.skip = true end,
  function() s.octave_shift = clamp(s.octave_shift + 1, -2, 2); s.chorus = true end,
  function() s.minimal = true; s.glide = true; s.scale = "dorian" end,
  function() s.vel_ramp = 1; s.scale = "acid"; s.vel_ramp_step = 0 end,
  function() s.minimal = true; s.pat_idx = 1; s.distort = true end,
  function() randomise_patch(); s.bpm = math.random(100, 170); if s.playing then start_seq() end end,
}

-- Grid action map: ACTIONS[row][col] = function | nil
local ACTIONS = {}

local function build_roulette()
  -- Fisher-Yates shuffle
  local pool = {}
  for _, a in ipairs(ACTION_POOL) do
    table.insert(pool, a)
  end
  for i = #pool, 2, -1 do
    local j = math.random(i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  -- tile to fill 126 slots
  local tiled = {}
  while #tiled < 126 do
    for _, a in ipairs(pool) do
      table.insert(tiled, a)
      if #tiled >= 126 then break end
    end
  end
  -- assign into grid (skip [1,1] and [1,2])
  local idx = 1
  for row = 1, 8 do
    ACTIONS[row] = {}
    for col = 1, 16 do
      if row == 1 and (col == 1 or col == 2) then
        ACTIONS[row][col] = nil
      else
        ACTIONS[row][col] = tiled[idx]
        idx = idx + 1
      end
    end
  end
end

--------------------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------------------

local CELL   = 4
local anim_t = 0
local flash_t = 0.0
local flash_label = ""

local HELMET_BODY = {
  {-3,-3},{-2,-3},{-1,-3},{0,-3},{1,-3},{2,-3},{3,-3},
  {-3,-2},{-2,-2},{-1,-2},{0,-2},{1,-2},{2,-2},{3,-2},
  {-3,-1},{-2,-1},{-1,-1},{0,-1},{1,-1},{2,-1},{3,-1},
  {-3, 0},{-2, 0},{-1, 0},{0, 0},{1, 0},{2, 0},{3, 0},
  {-2, 1},{-1, 1},{0, 1},{1, 1},{2, 1},
  {-1, 2},{0, 2},{1, 2},
}
local HELMET_VISOR = {
  {-2,0},{-1,0},{0,0},{1,0},{2,0},
}

local function draw_helmet(cx, cy, visor_bright, phase)
  local ox = math.floor(math.sin(anim_t * 0.8 + phase) * 3)
  local oy = math.floor(math.cos(anim_t * 0.6 + phase) * 2)
  for _, p in ipairs(HELMET_BODY) do
    local px = cx + (p[1] + ox) * CELL
    local py = cy + (p[2] + oy) * CELL
    if px >= 0 and px < 128 and py >= 0 and py < 64 then
      screen.level(5)
      screen.rect(px, py, CELL - 1, CELL - 1)
      screen.fill()
    end
  end
  for _, p in ipairs(HELMET_VISOR) do
    local px = cx + (p[1] + ox) * CELL
    local py = cy + (p[2] + oy) * CELL
    if px >= 0 and px < 128 and py >= 0 and py < 64 then
      local glow = clamp(math.floor(visor_bright + math.sin(anim_t * 3 + phase) * 3), 4, 15)
      screen.level(glow)
      screen.rect(px, py, CELL - 1, CELL - 1)
      screen.fill()
    end
  end
end

function redraw()
  screen.clear()

  -- scanlines
  for row = 0, 15 do
    if row % 2 == 0 then
      screen.level(1)
      screen.rect(0, row * 4, 128, 4)
      screen.fill()
    end
  end

  -- helmets
  draw_helmet(30, 36, 14, 0)
  draw_helmet(96, 36, 10, math.pi)

  -- HUD top
  screen.level(12)
  screen.font_size(8)
  screen.move(1, 9)
  screen.text(string.upper(s.scale))

  screen.level(8)
  screen.move(72, 9)
  screen.text(s.bpm .. "BPM")

  -- play dot
  if s.playing then
    local pulse = clamp(math.floor((math.sin(anim_t * 5) + 1) * 4) + 6, 6, 15)
    screen.level(pulse)
    screen.circle(64, 5, 2)
    screen.fill()
  end

  -- fx strip
  local fx = ""
  if s.chorus  then fx = fx .. "CHO "  end
  if s.minimal then fx = fx .. "MIN "  end
  if s.distort then fx = fx .. "DST "  end
  if s.stutter then fx = fx .. "STT/" .. s.stutter_div .. " " end
  if s.glide   then fx = fx .. "GLD "  end
  if s.cascade then fx = fx .. "CAS "  end
  if s.skip    then fx = fx .. "SKP "  end

  screen.level(5)
  screen.font_size(8)
  screen.move(1, 62)
  screen.text(fx)

  -- flash label
  if flash_t > 0 then
    screen.level(clamp(math.floor(flash_t * 14), 1, 15))
    screen.font_size(8)
    screen.move(64, 62)
    screen.text_center(flash_label)
    flash_t = math.max(0, flash_t - 0.08)
  end

  screen.update()
end

--------------------------------------------------------------------------------
-- GRID
--------------------------------------------------------------------------------

local g = grid.connect()

-- Pulsing roulette LEDs (positions change each refresh for alive feel)
local pulse_cells = {}
local function refresh_pulse_cells()
  pulse_cells = {}
  if s.playing then
    for _ = 1, 6 do
      local row = math.random(1, 8)
      local col = math.random(1, 16)
      if not (row == 1 and (col == 1 or col == 2)) then
        table.insert(pulse_cells, {row, col})
      end
    end
  end
end

local function grid_draw()
  if g == nil then return end
  g:all(0)

  -- transport keys
  g:led(1, 1, s.playing and 15 or 5)
  g:led(2, 1, s.playing and 4  or 12)

  -- dim all roulette keys
  for row = 1, 8 do
    for col = 1, 16 do
      if not (row == 1 and (col == 1 or col == 2)) then
        g:led(col, row, 2)
      end
    end
  end

  -- pulse overlay
  local pulse_lv = clamp(math.floor((math.sin(anim_t * 4) + 1) * 3) + 3, 3, 9)
  for _, pc in ipairs(pulse_cells) do
    g:led(pc[2], pc[1], pulse_lv)
  end

  g:refresh()
end

local FLASH_LABELS = {
  "SCALE","CHORD","PAT","OCT","BEND","BPM",
  "STUT","FX","GATE","VEL","ROOT","FILT","PATCH","COMBO","CHAOS","RESET"
}

local function grid_key(x, y, z)
  if z == 0 then return end  -- ignore key-up

  if y == 1 and x == 1 then
    start_seq()
    return
  end

  if y == 1 and x == 2 then
    stop_seq()
    return
  end

  local action = ACTIONS[y] and ACTIONS[y][x]
  if action then
    action()
    -- brief label: derived from position so it's consistent per session
    local slot = (y - 1) * 16 + x
    flash_label = FLASH_LABELS[(slot % #FLASH_LABELS) + 1]
    flash_t     = 1.0
  end
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function init()
  math.randomseed(os.time())

  apply_patch()
  engine.gain(0.8)

  build_roulette()

  if g ~= nil then
    g.key = grid_key
  end

  -- main clock: animation + grid refresh at ~12fps
  clock.run(function()
    while true do
      anim_t = anim_t + (1.0 / 12.0)
      refresh_pulse_cells()
      redraw()
      grid_draw()
      clock.sleep(1.0 / 12.0)
    end
  end)

  start_seq()
end

function cleanup()
  stop_seq()
end

--------------------------------------------------------------------------------
-- NORNS ENCODERS
--------------------------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    s.bpm = clamp(s.bpm + d, 60, 200)
    if s.playing then start_seq() end
  elseif n == 2 then
    s.root_midi = clamp(s.root_midi + d, 24, 60)
  elseif n == 3 then
    s.cutoff = clamp(s.cutoff + d * 100, 100, 8000)
    engine.cutoff(s.cutoff)
  end
end

--------------------------------------------------------------------------------
-- NORNS BUTTONS
--------------------------------------------------------------------------------

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    if s.playing then stop_seq() else start_seq() end
  elseif n == 3 then
    randomise_patch()
    flash_label = "PATCH"
    flash_t     = 1.0
  end
end
