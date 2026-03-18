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
  -- pattern memory
  saved_patterns = {{}, {}, {}, {}},
  pattern_slot = 1,
  -- stutter lock
  stutter_lock = false,
  stutter_lock_note = nil,
  stutter_lock_started = false,
  -- NEW: screen animation state
  beat_phase   = 0,
  popup_param  = nil,
  popup_val    = nil,
  popup_time   = 0,
  string_flash = {0, 0, 0, 0, 0, 0},  -- brightness for each string
  strum_dir    = 1,  -- 1 = down, -1 = up
  -- Filter LFO
  filter_lfo_rate = 0.25,  -- 8-16 bars
  filter_lfo_depth = 0,    -- 0-1
  -- MIDI out
  midi_enabled = false,
  midi_channel = 1,
  -- Multi-bar pattern
  bar_count = 1,           -- 1-4 bars
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

-- Save current roulette state + grid pattern to a slot
local function save_pattern(slot)
  if slot < 1 or slot > 4 then return end
  s.saved_patterns[slot] = {
    scale        = s.scale,
    chord        = s.chord,
    pat_idx      = s.pat_idx,
    octave_shift = s.octave_shift,
    pitch_bend   = s.pitch_bend,
    gate         = s.gate,
    velocity     = s.velocity,
    swing        = s.swing,
    chorus       = s.chorus,
    minimal      = s.minimal,
    distort      = s.distort,
    stutter      = s.stutter,
    stutter_div  = s.stutter_div,
    glide        = s.glide,
    skip         = s.skip,
    cascade      = s.cascade,
    vel_ramp     = s.vel_ramp,
    cutoff       = s.cutoff,
    pw           = s.pw,
    rel          = s.rel,
  }
end

-- Load pattern from a slot
local function load_pattern(slot)
  if slot < 1 or slot > 4 then return end
  local p = s.saved_patterns[slot]
  if not p or not p.scale then return end
  
  s.scale        = p.scale
  s.chord        = p.chord
  s.pat_idx      = p.pat_idx
  s.octave_shift = p.octave_shift
  s.pitch_bend   = p.pitch_bend
  s.gate         = p.gate
  s.velocity     = p.velocity
  s.swing        = p.swing
  s.chorus       = p.chorus
  s.minimal      = p.minimal
  s.distort      = p.distort
  s.stutter      = p.stutter
  s.stutter_div  = p.stutter_div
  s.glide        = p.glide
  s.skip         = p.skip
  s.cascade      = p.cascade
  s.vel_ramp     = p.vel_ramp
  s.cutoff       = p.cutoff or 2000
  s.pw           = p.pw or 0.5
  s.rel          = p.rel or 0.3
  apply_patch()
end

--------------------------------------------------------------------------------
-- AUDIO
--------------------------------------------------------------------------------

local prev_hz = 0
local midi_out = nil
local pattern_lfo_phase = 0  -- 0-1 for LFO

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

local function get_lfo_cutoff()
  local base_cutoff = s.cutoff
  local lfo_val = math.sin(pattern_lfo_phase * 2 * math.pi)  -- -1 to 1
  local lfo_amt = lfo_val * s.filter_lfo_depth * 4000  -- scale to Hz
  return clamp(base_cutoff + lfo_amt, 100, 8000)
end

local function play_note(midi, vel, dur)
  local hz = midi_to_hz(midi)
  if s.distort then
    hz = hz * (1.0 + (math.random() * 0.04 - 0.02))
  end
  local cut = s.chorus and clamp(s.cutoff * 1.5, 100, 8000) or get_lfo_cutoff()
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

  -- Send MIDI if enabled
  if s.midi_enabled and midi_out then
    midi_out:note_on(midi, math.floor(vel * 127), s.midi_channel)
    clock.run(function()
      clock.sleep(dur)
      midi_out:note_off(midi, 0, s.midi_channel)
    end)
  end

  -- Trigger strum flash animation
  for i = 1, 6 do
    s.string_flash[i] = 12
  end
end

--------------------------------------------------------------------------------
-- SEQUENCER
--------------------------------------------------------------------------------

local seq_id = nil
local stutter_seq_id = nil

local function step_sec()
  local base = 60.0 / s.bpm / 4.0
  return base / (s.stutter and s.stutter_div or 1)
end

local function pattern_len_steps()
  -- Multi-bar pattern: bar_count (1-4) determines steps
  -- 1 bar = 16 steps, 2 bars = 32 steps, etc.
  return 16 * s.bar_count
end

-- Stutter lock: rapidly re-trigger the current note
local function stutter_lock_trigger(midi, vel, base_dur)
  if stutter_seq_id then clock.cancel(stutter_seq_id) end
  
  local stutter_rate = params:get("stutter_rate") or 16  -- 1/16 or 1/32
  local stutter_dur = (60.0 / s.bpm / 4.0) / stutter_rate
  
  stutter_seq_id = clock.run(function()
    while s.stutter_lock do
      play_note(midi, vel, stutter_dur * 0.5)
      clock.sleep(stutter_dur)
    end
  end)
end

local function advance()
  if s.skip and math.random() < 0.4 then
    s.step = (s.step % (pattern_len_steps() + 1))
    if s.step == 0 then s.step = 1 end
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
      local note = scale_note(base_deg)
      play_note(note, vel, dur)
      if s.stutter_lock then
        s.stutter_lock_note = note
        stutter_lock_trigger(note, vel, dur)
      end
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
      if s.stutter_lock then
        s.stutter_lock_note = notes[1]
        stutter_lock_trigger(notes[1], vel, dur)
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
      if s.stutter_lock then
        s.stutter_lock_note = notes[1]
        stutter_lock_trigger(notes[1], vel, dur)
      end
    end
  end

  s.step = (s.step % pattern_len_steps()) + 1
end

local function start_seq()
  if seq_id then clock.cancel(seq_id) end
  if stutter_seq_id then clock.cancel(stutter_seq_id) end
  s.playing = true
  s.stutter_lock_started = s.stutter_lock
  seq_id = clock.run(function()
    while true do
      advance()
      clock.sleep(step_sec())
    end
  end)
end

local function stop_seq()
  s.playing = false
  s.stutter_lock = false
  if seq_id then
    clock.cancel(seq_id)
    seq_id = nil
  end
  if stutter_seq_id then
    clock.cancel(stutter_seq_id)
    stutter_seq_id = nil
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
-- SCREEN - NEW DESIGN SYSTEM
--------------------------------------------------------------------------------

local anim_frame = 0

local function draw_status_strip()
  -- y: 0-8
  screen.level(4)
  screen.font_size(8)
  screen.move(1, 8)
  screen.text("HBF")
  
  -- Current chord at center, level 12
  screen.level(12)
  screen.move(64, 8)
  screen.text_center(string.upper(s.chord))
  
  -- Pattern slot P1-P4 at right, level 8
  screen.level(8)
  screen.move(120, 8)
  screen.text("P" .. s.pattern_slot)
  
  -- Beat pulse dot at x=124, y=4
  if s.playing then
    local pulse = clamp(math.floor((math.sin(anim_frame * 0.5) + 1) * 4) + 8, 8, 15)
    screen.level(pulse)
    screen.circle(124, 4, 2)
    screen.fill()
  end
end

local function draw_live_zone()
  -- y: 9-52, show 6 horizontal strings with current chord notes
  local y_base = 15
  local y_spacing = 6
  local x_start = 20
  local x_end = 110
  local offsets = CHORDS[s.chord]
  
  -- Draw 6 string lines at level 3
  for i = 1, 6 do
    screen.level(3)
    local y = y_base + (i - 1) * y_spacing
    screen.move(x_start, y)
    screen.line(x_end, y)
    screen.stroke()
  end
  
  -- Draw chord note dots at level 12
  -- Map chord offsets to string positions (simplified: show first 6 offsets or repeat)
  for i = 1, 6 do
    local offset_idx = ((i - 1) % #offsets) + 1
    local x = x_start + (x_end - x_start) * (offset_idx / (#offsets + 1))
    local y = y_base + (i - 1) * y_spacing
    
    -- Flash from string_flash state
    local brightness = clamp(s.string_flash[i], 3, 12)
    screen.level(brightness)
    screen.circle(x, y, 2)
    screen.fill()
  end
  
  -- Draw strum direction arrow (up/down) at level 8, animates briefly on strum
  local arrow_x = 115
  local arrow_y = 30
  screen.level(8)
  screen.font_size(8)
  if s.strum_dir == 1 then
    screen.move(arrow_x, arrow_y)
    screen.text("v")
  else
    screen.move(arrow_x, arrow_y)
    screen.text("^")
  end
end

local function draw_pattern_memory()
  -- Show 4 small slots, level 3-4, active slot at level 12
  local slot_x = 10
  local slot_y = 40
  local slot_spacing = 8
  
  for i = 1, 4 do
    local x = slot_x + (i - 1) * slot_spacing
    if i == s.pattern_slot then
      screen.level(12)
    else
      screen.level(3)
    end
    screen.rect(x, slot_y, 6, 6)
    screen.fill()
  end
end

local function draw_context_bar()
  -- y: 53-58
  screen.level(6)
  screen.font_size(8)
  screen.move(1, 63)
  screen.text("DIR:" .. (s.strum_dir == 1 and "DN" or "UP"))
  
  screen.level(5)
  screen.move(30, 63)
  screen.text("STUT:" .. (s.stutter and s.stutter_div or "-"))
  
  screen.level(5)
  screen.move(60, 63)
  screen.text("VOI:" .. string.upper(s.chord))
  
  screen.level(4)
  screen.move(100, 63)
  screen.text("CH:" .. (1 + (s.root_midi % 12)))
end

local function draw_popup()
  -- Transient parameter popup at 0.8s duration
  if s.popup_time > 0 then
    local alpha = clamp(s.popup_time / 0.8, 0, 1)
    local brightness = clamp(math.floor(alpha * 12), 3, 12)
    
    -- Semi-transparent background
    screen.level(2)
    screen.rect(40, 20, 50, 20)
    screen.fill()
    
    -- Popup text
    screen.level(brightness)
    screen.font_size(8)
    screen.move(65, 30)
    screen.text_center(s.popup_param or "")
    
    screen.move(65, 38)
    screen.text_center(tostring(s.popup_val or ""))
  end
end

local function draw_stutter_flicker()
  -- Stutter lock visual: flicker chord name at stutter rate
  if s.stutter_lock then
    local stutter_rate = params:get("stutter_rate") or 16
    local flicker_period = (1.0 / stutter_rate) * 4  -- rough sync to stutter
    local flicker = math.floor((anim_frame % flicker_period) * 2) % 2
    
    if flicker == 1 then
      screen.level(15)
      screen.font_size(8)
      screen.move(64, 8)
      screen.text_center(string.upper(s.chord))
    end
  end
end

function redraw()
  screen.clear()
  screen.aa(1)  -- anti-alias
  
  -- Scanlines effect
  for row = 0, 15 do
    if row % 2 == 0 then
      screen.level(1)
      screen.rect(0, row * 4, 128, 4)
      screen.fill()
    end
  end
  
  draw_status_strip()
  draw_live_zone()
  draw_pattern_memory()
  draw_context_bar()
  draw_popup()
  draw_stutter_flicker()
  
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
  local pulse_lv = clamp(math.floor((math.sin(anim_frame * 0.4) + 1) * 3) + 3, 3, 9)
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
    -- Show popup with action label
    local slot = (y - 1) * 16 + x
    s.popup_param = FLASH_LABELS[(slot % #FLASH_LABELS) + 1]
    s.popup_val = s.chord
    s.popup_time = 0.8
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

  -- add pattern memory and stutter lock params
  params:add_separator("pattern_memory", "PATTERN MEMORY")
  params:add_number("pattern_slot", "pattern slot", 1, 4, 1)
  params:set_action("pattern_slot", function(v)
    s.pattern_slot = v
    load_pattern(v)
  end)

  params:add_separator("stutter_lock_cfg", "STUTTER LOCK")
  params:add_number("stutter_rate", "stutter rate", 16, 32, 16)

  -- Filter LFO params
  params:add_separator("filter_lfo", "FILTER AUTOMATION")
  params:add_control("filter_lfo_rate", "LFO rate",
    controlspec.new(0.05, 1.0, "lin", 0.05, 0.25, ""))
  params:set_action("filter_lfo_rate", function(v) s.filter_lfo_rate = v end)
  params:add_control("filter_lfo_depth", "LFO depth",
    controlspec.new(0, 1.0, "lin", 0.01, 0, ""))
  params:set_action("filter_lfo_depth", function(v) s.filter_lfo_depth = v end)

  -- MIDI out params
  params:add_separator("midi_out_cfg", "MIDI OUT")
  params:add_option("midi_enabled", "MIDI OUT", {"OFF", "ON"}, 1)
  params:set_action("midi_enabled", function(v) s.midi_enabled = (v == 2) end)
  params:add_number("midi_channel", "MIDI CH", 1, 16, 1)
  params:set_action("midi_channel", function(v) s.midi_channel = v end)

  -- Multi-bar pattern param
  params:add_separator("pattern_cfg", "PATTERN")
  params:add_number("bar_count", "bar count", 1, 4, 1)
  params:set_action("bar_count", function(v) s.bar_count = v end)

  if g ~= nil then
    g.key = grid_key
  end

  -- Connect MIDI out
  midi_out = midi.connect(params:get("midi_out_device") or 1)

  -- main clock: animation + grid refresh at ~12fps
  clock.run(function()
    while true do
      anim_frame = anim_frame + 1

      -- Update filter LFO phase (8-16 bars = 8-16 seconds at 120 BPM)
      -- rate 0.25 = 1 bar cycle at 120 BPM, 0.05 = 5 bar cycle, etc.
      pattern_lfo_phase = (pattern_lfo_phase + (1.0/12.0) * s.filter_lfo_rate / 4.0) % 1.0

      -- Decay string flash values
      for i = 1, 6 do
        s.string_flash[i] = math.max(3, s.string_flash[i] - 1.5)
      end

      -- Decay popup time
      if s.popup_time > 0 then
        s.popup_time = s.popup_time - (1.0 / 12.0)
      end

      s.beat_phase = (s.beat_phase + 1) % 360
      refresh_pulse_cells()
      redraw()
      grid_draw()
      clock.sleep(1.0 / 12.0)
    end
  end)

  params:bang()
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
    s.popup_param = "BPM"
    s.popup_val = s.bpm
    s.popup_time = 0.8
    if s.playing then start_seq() end
  elseif n == 2 then
    s.root_midi = clamp(s.root_midi + d, 24, 60)
    s.popup_param = "ROOT"
    s.popup_val = s.root_midi
    s.popup_time = 0.8
  elseif n == 3 then
    s.cutoff = clamp(s.cutoff + d * 100, 100, 8000)
    s.popup_param = "CUTOFF"
    s.popup_val = s.cutoff
    s.popup_time = 0.8
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
    s.popup_param = "PATCH"
    s.popup_val = "RND"
    s.popup_time = 0.8
  end
end