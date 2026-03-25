-- midimix.lua: Akai MIDIMIX controller for MIDI JUKEBOX
--
-- LAYOUT (channels 1-8 map to tracks 1-8):
--   Knob Row 1 (1-8): MIDI output channel per track
--   Knob Row 2 (1-7): Program Change per track, (8): drum LPF filter
--   Knob Row 3 (8): drum resonance
--   Mute 1-8: track mute toggle
--   Rec 1-8: toggle all-channel broadcast
--   Faders 1-8: track velocity
--   Bank Left/Right: prev/next song in queue
--
-- LEDs: mute buttons light when track is NOT muted

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
local REC_NOTES  = {3, 6, 9, 12, 15, 18, 21, 24}
local BANK_LEFT_NOTE = 25
local BANK_RIGHT_NOTE = 26
local BANK_LEFT_CC = 25
local BANK_RIGHT_CC = 26
local SEND_ALL_NOTE = 27  -- solo button above master fader = PANIC

-- Scale CC value (0-127) to a range
local function cc_to_range(val, min, max)
  local steps = max - min
  local step = math.floor((val / 127) * steps + 0.5)
  return min + step
end

function MidiMix.new()
  local self = setmetatable({}, MidiMix)

  self.midi_in = nil

  -- Callbacks (set by main script) - all use track index (1-8)
  self.on_velocity = nil      -- function(track_idx, velocity_0_to_1)
  self.on_channel = nil       -- function(track_idx, midi_ch)
  self.on_program_change = nil -- function(track_idx, pc_num)
  self.on_mute_toggle = nil   -- function(track_idx)
  self.on_all_toggle = nil    -- function(track_idx) toggle all-channel broadcast
  self.on_prev_song = nil     -- function()
  self.on_next_song = nil     -- function()
  self.on_filter = nil        -- function(freq)
  self.on_resonance = nil     -- function(res)
  self.on_panic = nil         -- function()  -- SEND ALL button = panic
  self.on_bpm = nil           -- function(bpm)  -- master fader = BPM

  -- Build reverse lookup tables
  self._fader_map = {}
  self._knob1_map = {}
  self._knob2_map = {}
  self._knob3_map = {}
  self._mute_map = {}
  self._rec_map = {}

  for i = 1, 8 do
    self._fader_map[FADER_CC[i]] = i
    self._knob1_map[KNOB_ROW1[i]] = i
    self._knob2_map[KNOB_ROW2[i]] = i
    self._knob3_map[KNOB_ROW3[i]] = i
    self._mute_map[MUTE_NOTES[i]] = i
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
  -- Start with all LEDs off
  self:leds_off()
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
  -- Faders 1-8: track velocity
  local fader_idx = self._fader_map[cc]
  if fader_idx then
    local vel = val / 127
    if self.on_velocity then self.on_velocity(fader_idx, vel) end
    return
  end

  -- Knob Row 1 (1-8): MIDI output channel per track
  local k1 = self._knob1_map[cc]
  if k1 then
    local ch = cc_to_range(val, 1, 16)
    if self.on_channel then self.on_channel(k1, ch) end
    return
  end

  -- Knob Row 2 (1-7): Program Change per track, (8): drum LPF filter
  local k2 = self._knob2_map[cc]
  if k2 then
    if k2 == 8 then
      -- Logarithmic mapping: 0=60Hz, 127=20kHz
      local freq = 60 * math.pow(20000/60, val/127)
      if val == 127 then freq = 20000 end
      if self.on_filter then self.on_filter(freq) end
    else
      -- Program Change 0-127
      if self.on_program_change then self.on_program_change(k2, val) end
    end
    return
  end

  -- Knob Row 3 (8): drum resonance
  local k3 = self._knob3_map[cc]
  if k3 and k3 == 8 then
    local res = 0.1 + (val / 127) * 0.9  -- 0.1 to 1.0
    if self.on_resonance then self.on_resonance(res) end
    return
  end

  -- Master fader: BPM
  if cc == MASTER_CC then
    local bpm = math.floor(20 + (val / 127) * 280)  -- 20-300 BPM
    if self.on_bpm then self.on_bpm(bpm) end
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
  -- Mute buttons 1-8: track mute toggle
  local mute_idx = self._mute_map[note]
  if mute_idx then
    if self.on_mute_toggle then self.on_mute_toggle(mute_idx) end
    return
  end

  -- Rec buttons 1-8: toggle all-channel broadcast
  local rec_idx = self._rec_map[note]
  if rec_idx then
    if self.on_all_toggle then self.on_all_toggle(rec_idx) end
    return
  end

  -- SEND ALL / solo above master = PANIC
  if note == SEND_ALL_NOTE then
    if self.on_panic then self.on_panic() end
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

-- Update LEDs to reflect mute state for tracks
function MidiMix:update_leds(tracks)
  if not self.midi_in then return end
  for i = 1, 8 do
    local note = MUTE_NOTES[i]
    local track = tracks and tracks[i]
    -- LED on = not muted AND has volume
    local vel = track and (track.velocity_scale or 1)
    if track and not track.mute and vel > 0 then
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
