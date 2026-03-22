-- midimix.lua: Akai MIDIMIX controller for MIDI PLAYBOX
-- Adapted from midi-sines midimix driver
--
-- LAYOUT (channels 1-4 used, 5-8 spare):
--   Faders 1-4: track velocity (bass/chords/lead/drum)
--   Knob Row 1 (1-3): octave per synth track, (4): drum kit
--   Knob Row 2 (4): drum LPF filter
--   Knob Row 3 (4): drum random amount
--   Mute 1-4: track mute toggle
--   Solo 1-4: cycle source MIDI channel
--   Rec 1-4: (spare)
--   Master fader: BPM
--   Bank Left/Right: prev/next song in queue
--
-- LEDs: mute buttons light when track is NOT muted
-- NOTE: MIDI out channels are set via params/Norns menu only (safer for live use)

local MidiMix = {}
MidiMix.__index = MidiMix

-- MIDIMIX CC assignments
local FADER_CC = {19, 23, 27, 31, 49, 53, 57, 61}
local MASTER_CC = 62
local KNOB_ROW1 = {16, 20, 24, 28, 46, 50, 54, 58}
local KNOB_ROW2 = {17, 21, 25, 29, 47, 51, 55, 59}
local KNOB_ROW3 = {18, 22, 26, 30, 48, 52, 56, 60}

-- MIDIMIX button notes
local MUTE_NOTES = {1, 4, 7, 10, 13, 16, 19, 22}
local SOLO_NOTES = {2, 5, 8, 11, 14, 17, 20, 23}
local REC_NOTES  = {3, 6, 9, 12, 15, 18, 21, 24}
local BANK_LEFT_NOTE = 25
local BANK_RIGHT_NOTE = 26
local BANK_LEFT_CC = 25
local BANK_RIGHT_CC = 26

-- Track names in order
local TRACKS = {"bass", "chords", "lead", "drum"}

-- Scale CC value (0-127) to a range
local function cc_to_range(val, min, max)
  local steps = max - min
  local step = math.floor((val / 127) * steps + 0.5)
  return min + step
end

function MidiMix.new()
  local self = setmetatable({}, MidiMix)

  self.midi_in = nil

  -- Callbacks (set by main script)
  self.on_velocity = nil      -- function(track_name, velocity_0_to_1)
  self.on_octave = nil        -- function(track_name, octave)
  self.on_mute_toggle = nil   -- function(track_name)
  self.on_all_toggle = nil    -- function(track_name) toggle all-channel broadcast
  self.on_bpm = nil           -- function(bpm)
  self.on_prev_song = nil     -- function()
  self.on_next_song = nil     -- function()
  self.on_kit = nil           -- function(kit_index)  -- 1-4
  self.on_filter = nil        -- function(freq)
  self.on_random_amt = nil    -- function(amount)  -- 0-1

  -- Build reverse lookup tables
  self._fader_map = {}
  self._knob1_map = {}
  self._knob2_map = {}
  self._knob3_map = {}
  self._mute_map = {}
  self._solo_map = {}
  self._rec_map = {}

  for i = 1, 8 do
    self._fader_map[FADER_CC[i]] = i
    self._knob1_map[KNOB_ROW1[i]] = i
    self._knob2_map[KNOB_ROW2[i]] = i
    self._knob3_map[KNOB_ROW3[i]] = i
    self._mute_map[MUTE_NOTES[i]] = i
    self._solo_map[SOLO_NOTES[i]] = i
    self._rec_map[REC_NOTES[i]] = i
  end

  return self
end

function MidiMix:connect(device_num)
  self.midi_in = midi.connect(device_num)
  self.midi_in.event = function(data)
    self:handle_event(data)
  end
  print("MIDIMIX connected on device " .. device_num)
end

function MidiMix:handle_event(data)
  local msg = midi.to_msg(data)

  if msg.type == "cc" then
    self:handle_cc(msg.cc, msg.val)
  elseif msg.type == "note_on" and msg.vel > 0 then
    self:handle_note(msg.note)
  end
end

function MidiMix:handle_cc(cc, val)
  -- Faders 1-4: track velocity
  local fader_ch = self._fader_map[cc]
  if fader_ch and fader_ch <= 4 then
    local track = TRACKS[fader_ch]
    local vel = val / 127
    if self.on_velocity then self.on_velocity(track, vel) end
    return
  end

  -- Master fader: disabled (too easy to bump live)
  -- if cc == MASTER_CC then
  -- end

  -- Knob Row 1 (1-3): octave per synth track
  local k1 = self._knob1_map[cc]
  if k1 and k1 <= 3 then
    local track = TRACKS[k1]
    local octave = cc_to_range(val, -3, 3)
    if self.on_octave then self.on_octave(track, octave) end
    return
  end
  -- Knob Row 1 (4): drum kit select
  if k1 and k1 == 4 then
    local kit = cc_to_range(val, 1, 4)
    if self.on_kit then self.on_kit(kit) end
    return
  end

  -- Knob Row 2 (4): drum LPF filter
  local k2 = self._knob2_map[cc]
  if k2 and k2 == 4 then
    -- Logarithmic mapping: 0=60Hz, 127=20kHz
    local freq = 60 * math.pow(20000/60, val/127)
    if val == 127 then freq = 20000 end
    if self.on_filter then self.on_filter(freq) end
    return
  end

  -- Knob Row 3 (4): drum random amount
  local k3 = self._knob3_map[cc]
  if k3 and k3 == 4 then
    local amt = val / 127
    if self.on_random_amt then self.on_random_amt(amt) end
    return
  end

  -- Bank buttons (CC variant)
  if cc == BANK_LEFT_CC and val == 127 then
    if self.on_prev_song then self.on_prev_song() end
    return
  end
  if cc == BANK_RIGHT_CC and val == 127 then
    if self.on_next_song then self.on_next_song() end
    return
  end
end

function MidiMix:handle_note(note)
  -- Mute buttons 1-4: track mute toggle
  local mute_ch = self._mute_map[note]
  if mute_ch and mute_ch <= 4 then
    local track = TRACKS[mute_ch]
    if self.on_mute_toggle then self.on_mute_toggle(track) end
    return
  end

  -- Rec buttons 1-4: toggle all-channel broadcast
  local rec_ch = self._rec_map[note]
  if rec_ch and rec_ch <= 4 then
    local track = TRACKS[rec_ch]
    if self.on_all_toggle then self.on_all_toggle(track) end
    return
  end

  -- Bank buttons (note variant)
  if note == BANK_LEFT_NOTE then
    if self.on_prev_song then self.on_prev_song() end
    return
  end
  if note == BANK_RIGHT_NOTE then
    if self.on_next_song then self.on_next_song() end
    return
  end
end

-- Update LEDs to reflect mute state
-- mute_table: { bass=bool, chords=bool, lead=bool, drum=bool }
function MidiMix:update_leds(mute_table)
  if not self.midi_in then return end
  for i = 1, 4 do
    local track = TRACKS[i]
    local note = MUTE_NOTES[i]
    if mute_table and not mute_table[track] then
      -- LED on = track active (not muted)
      self.midi_in:note_on(note, 127, 1)
    else
      self.midi_in:note_off(note, 0, 1)
    end
  end
end

function MidiMix:leds_off()
  if not self.midi_in then return end
  for i = 1, 8 do
    self.midi_in:note_off(MUTE_NOTES[i], 0, 1)
  end
end

return MidiMix
