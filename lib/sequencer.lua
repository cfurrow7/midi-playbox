-- sequencer.lua: MIDI playback engine with clock-based timing
-- Routes synth tracks to MIDI out, drum track to internal engine

local MidiParser = include("midi-playbox/lib/midi_parser")
local TrackAssign = include("midi-playbox/lib/track_assign")

local Sequencer = {}
Sequencer.__index = Sequencer

function Sequencer.new()
  local self = setmetatable({}, Sequencer)

  self.midi_out = nil         -- midi device
  self.parsed = nil           -- parsed MIDI data
  self.timeline = nil         -- merged event list
  self.duration = 0           -- song duration in seconds

  self.playing = false
  self.clock_id = nil
  self.position = 1           -- current event index
  self.elapsed = 0            -- playback time in seconds

  -- Track assignment
  self.assignment = nil       -- { bass={ch,name}, chords={ch,name}, lead={ch,name}, drum={ch,name} }

  -- Output config (user-configurable MIDI channels)
  self.out_channels = {
    bass = 1,
    chords = 2,
    lead = 3,
  }

  -- Per-track octave offset
  self.octave = {
    bass = 0,
    chords = 0,
    lead = 0,
  }

  -- BPM
  self.original_bpm = 120
  self.bpm_override = nil     -- nil = use original

  -- Callbacks
  self.on_note = nil          -- function(track, note, vel) for UI feedback
  self.on_end = nil           -- function() called when song ends
  self.on_progress = nil      -- function(elapsed, duration)

  -- Active notes (for cleanup on stop)
  self.active_notes = {}      -- { {ch, note}, ... }

  return self
end

function Sequencer:connect_midi(device_num)
  self.midi_out = midi.connect(device_num or 1)
end

function Sequencer:load(filepath)
  local parsed, err = MidiParser.parse(filepath)
  if not parsed then return false, err end

  self.parsed = parsed
  self.original_bpm = parsed.bpm
  self.assignment = TrackAssign.auto_assign(parsed.channels)

  -- Rebuild timeline
  self:rebuild_timeline()

  return true
end

function Sequencer:rebuild_timeline()
  if not self.parsed then return end
  local bpm = self.bpm_override or self.original_bpm
  self.timeline, self.duration = MidiParser.to_timeline(self.parsed, bpm)
  self.position = 1
  self.elapsed = 0
end

function Sequencer:get_bpm()
  return self.bpm_override or self.original_bpm
end

function Sequencer:set_bpm(bpm)
  if bpm then
    self.bpm_override = math.max(20, math.min(300, bpm))
  else
    self.bpm_override = nil
  end
  -- Rebuild timeline with new tempo
  local was_playing = self.playing
  if was_playing then self:stop() end
  self:rebuild_timeline()
  if was_playing then self:play() end
end

function Sequencer:play()
  if not self.timeline or #self.timeline == 0 then return end
  if self.playing then return end

  self.playing = true

  self.clock_id = clock.run(function()
    local start_time = clock.get_beat_sec and util.time() or util.time()
    local start_elapsed = self.elapsed

    while self.playing and self.position <= #self.timeline do
      local event = self.timeline[self.position]
      local target_time = event.time - start_elapsed

      -- Wait until event time
      local now = util.time() - start_time
      if target_time > now then
        clock.sleep(target_time - now)
      end

      if not self.playing then break end

      -- Route the event
      self:route_event(event)

      self.elapsed = start_elapsed + (util.time() - start_time)
      self.position = self.position + 1

      -- Progress callback
      if self.on_progress then
        self.on_progress(self.elapsed, self.duration)
      end
    end

    -- Song ended
    if self.playing and self.position > #self.timeline then
      self.playing = false
      self:all_notes_off()
      if self.on_end then self.on_end() end
    end
  end)
end

function Sequencer:stop()
  self.playing = false
  if self.clock_id then
    clock.cancel(self.clock_id)
    self.clock_id = nil
  end
  self:all_notes_off()
end

function Sequencer:restart()
  self:stop()
  self.position = 1
  self.elapsed = 0
  self:play()
end

function Sequencer:route_event(event)
  if not self.assignment then return end

  local source_ch = event.channel

  -- Check which track this channel belongs to
  local track_name = nil
  for _, role in ipairs({"bass", "chords", "lead", "drum"}) do
    if self.assignment[role] and self.assignment[role].ch == source_ch then
      track_name = role
      break
    end
  end

  if not track_name then return end  -- unassigned channel, skip

  if track_name == "drum" then
    -- Route to internal drum engine
    if event.type == "note_on" and event.velocity > 0 then
      local voice = TrackAssign.map_drum_note(event.note)
      if voice then
        engine.trig_kit(voice, event.velocity / 127)
        if self.on_note then
          self.on_note("drum", event.note, event.velocity)
        end
      end
    end
  else
    -- Route to MIDI out
    if self.midi_out then
      local out_ch = self.out_channels[track_name] or 1
      local note = event.note + (self.octave[track_name] or 0) * 12
      note = math.max(0, math.min(127, note))

      if event.type == "note_on" and event.velocity > 0 then
        self.midi_out:note_on(note, event.velocity, out_ch)
        table.insert(self.active_notes, { out_ch, note })
        if self.on_note then
          self.on_note(track_name, note, event.velocity)
        end
      elseif event.type == "note_off" or (event.type == "note_on" and event.velocity == 0) then
        self.midi_out:note_off(note, 0, out_ch)
        -- Remove from active notes
        for i = #self.active_notes, 1, -1 do
          if self.active_notes[i][1] == out_ch and self.active_notes[i][2] == note then
            table.remove(self.active_notes, i)
            break
          end
        end
      end
    end
  end
end

function Sequencer:all_notes_off()
  if self.midi_out then
    for _, an in ipairs(self.active_notes) do
      self.midi_out:note_off(an[2], 0, an[1])
    end
    self.active_notes = {}
    -- Also send all notes off CC on all used channels
    for _, role in ipairs({"bass", "chords", "lead"}) do
      local ch = self.out_channels[role]
      if ch then
        self.midi_out:cc(123, 0, ch)  -- all notes off
      end
    end
  end
end

-- Get assignment info for display
function Sequencer:get_track_info()
  local info = {}
  for _, role in ipairs({"bass", "chords", "lead", "drum"}) do
    if self.assignment and self.assignment[role] then
      info[role] = {
        ch = self.assignment[role].ch,
        name = self.assignment[role].name,
        out_ch = role ~= "drum" and self.out_channels[role] or nil,
        octave = self.octave[role] or 0,
      }
    else
      info[role] = { ch = nil, name = "---", out_ch = nil, octave = 0 }
    end
  end
  return info
end

-- Manual track reassignment: swap a role to a different source channel
function Sequencer:set_source_channel(role, new_ch)
  if not self.assignment then return end
  if self.assignment[role] then
    self.assignment[role].ch = new_ch
    -- Update name from parsed channels
    if self.parsed and self.parsed.channels[new_ch] then
      self.assignment[role].name = self.parsed.channels[new_ch].name or ("Ch " .. new_ch)
    else
      self.assignment[role].name = "Ch " .. new_ch
    end
  else
    self.assignment[role] = { ch = new_ch, name = "Ch " .. new_ch }
  end
end

-- Get list of available source channels
function Sequencer:get_available_channels()
  if not self.parsed then return {} end
  local channels = {}
  for ch, _ in pairs(self.parsed.channels) do
    table.insert(channels, ch)
  end
  table.sort(channels)
  return channels
end

return Sequencer
