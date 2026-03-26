-- sequencer.lua: MIDI playback engine with clock-based timing
-- Dynamic track count - routes each track to MIDI out or internal drum engine

local MidiParser = include("midi-playbox/lib/midi_parser")
local TrackAssign = include("midi-playbox/lib/track_assign")

local Sequencer = {}
Sequencer.__index = Sequencer

function Sequencer.new()
  local self = setmetatable({}, Sequencer)

  self.midi_out = nil
  self.parsed = nil
  self.timeline = nil
  self.duration = 0

  self.playing = false
  self.clock_id = nil
  self.position = 1
  self.elapsed = 0

  -- Dynamic track list (built from MIDI file)
  self.tracks = {}  -- array of track objects

  -- BPM
  self.original_bpm = 120
  self.bpm_override = nil

  -- MIDI filter settings
  self.quantize_div = 0    -- 0=off, 8=1/8, 16=1/16, 32=1/32
  self.min_velocity = 0    -- 0=off, or threshold (e.g. 20)
  self.min_duration = 0    -- 0=off, or seconds (e.g. 0.05)

  -- Internal synth voice allocator (8 slots, round-robin)
  self.synth_next_slot = 0
  self.synth_note_map = {}  -- note -> slot

  -- Callbacks
  self.on_note = nil       -- function(track_idx, note, vel, drum_voice)
  self.on_end = nil
  self.on_progress = nil

  -- Active notes for cleanup
  self.active_notes = {}

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

  -- Build tracks from MIDI channels
  self.tracks = TrackAssign.build_tracks(parsed.channels)

  -- Rebuild timeline
  self:rebuild_timeline()

  return true
end

function Sequencer:rebuild_timeline()
  if not self.parsed then return end
  local bpm = self.bpm_override or self.original_bpm
  self.timeline, self.duration = MidiParser.to_timeline(self.parsed, bpm)
  -- Apply MIDI filter
  self.timeline = MidiParser.filter_timeline(
    self.timeline, bpm,
    self.quantize_div, self.min_velocity, self.min_duration
  )
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
    local start_time = util.time()
    local start_elapsed = self.elapsed

    while self.playing and self.position <= #self.timeline do
      local event = self.timeline[self.position]
      local target_time = event.time - start_elapsed

      local now = util.time() - start_time
      if target_time > now then
        clock.sleep(target_time - now)
      end

      if not self.playing then break end

      self:route_event(event)

      self.elapsed = start_elapsed + (util.time() - start_time)
      self.position = self.position + 1

      if self.on_progress then
        self.on_progress(self.elapsed, self.duration)
      end
    end

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

-- Find track by source MIDI channel
function Sequencer:track_for_channel(ch)
  for i, track in ipairs(self.tracks) do
    if track.source_ch == ch then
      return i, track
    end
  end
  return nil, nil
end

function Sequencer:route_event(event)
  local track_idx, track = self:track_for_channel(event.channel)
  if not track then return end

  -- Check mute
  if track.mute then return end

  -- Check output mode
  if track.output == "off" then return end

  if track.output == "internal" then
    -- Route to internal drum engine
    if event.type == "note_on" and event.velocity > 0 then
      local voice = TrackAssign.map_drum_note(event.note)
      if voice then
        local vel = (event.velocity / 127) * (track.velocity_scale or 1.0)
        engine.trig_kit(voice, vel)
        if self.on_note then
          self.on_note(track_idx, event.note, event.velocity, voice)
        end
      end
    end
  elseif track.output == "nb" then
    -- Route to nb voice (Doubledecker, MollyThePoly, PolyPerc, etc.)
    local note = event.note + (track.octave or 0) * 12
    note = math.max(0, math.min(127, note))

    -- get_nb_player is defined in main script
    local player = get_nb_player and get_nb_player(track_idx)
    if player then
      if event.type == "note_on" and event.velocity > 0 then
        local scale = track.velocity_scale or 1.0
        if scale <= 0.01 then return end
        local vel = (event.velocity / 127) * scale
        player:note_on(note, vel)
        if self.on_note then
          self.on_note(track_idx, note, math.floor(event.velocity * scale))
        end
      elseif event.type == "note_off" or (event.type == "note_on" and event.velocity == 0) then
        player:note_off(note)
      end
    end
  elseif track.output == "midi" then
    -- Route to MIDI out (supports multiple channels)
    if self.midi_out then
      local channels = track.out_channels or {1}
      local note = event.note + (track.octave or 0) * 12
      note = math.max(0, math.min(127, note))

      if event.type == "note_on" and event.velocity > 0 then
        local scale = track.velocity_scale or 1.0
        if scale <= 0.01 then return end
        local scaled_vel = math.floor(event.velocity * scale)
        scaled_vel = math.max(1, math.min(127, scaled_vel))
        for _, out_ch in ipairs(channels) do
          self.midi_out:note_on(note, scaled_vel, out_ch)
          table.insert(self.active_notes, { out_ch, note })
        end
        if self.on_note then
          self.on_note(track_idx, note, scaled_vel)
        end
      elseif event.type == "note_off" or (event.type == "note_on" and event.velocity == 0) then
        for _, out_ch in ipairs(channels) do
          self.midi_out:note_off(note, 0, out_ch)
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
end

function Sequencer:all_notes_off()
  -- Kill nb voices
  for i = 1, 8 do
    local player = get_nb_player and get_nb_player(i)
    if player and player.stop_all then player:stop_all() end
  end

  if self.midi_out then
    for _, an in ipairs(self.active_notes) do
      self.midi_out:note_off(an[2], 0, an[1])
    end
    self.active_notes = {}
    -- Send all notes off on all used output channels
    local sent = {}
    for _, track in ipairs(self.tracks) do
      if track.output == "midi" then
        for _, ch in ipairs(track.out_channels or {}) do
          if not sent[ch] then
            self.midi_out:cc(123, 0, ch)
            sent[ch] = true
          end
        end
      end
    end
  end
end

function Sequencer:toggle_mute(track_idx)
  local track = self.tracks[track_idx]
  if not track then return end
  track.mute = not track.mute
  -- If muting a MIDI track, send all notes off
  if track.mute and track.output == "midi" and self.midi_out then
    for _, ch in ipairs(track.out_channels or {}) do
      self.midi_out:cc(123, 0, ch)
    end
  end
end

-- Cycle output mode for a track: midi -> internal -> off -> midi
function Sequencer:cycle_output(track_idx)
  local track = self.tracks[track_idx]
  if not track then return end
  if track.output == "midi" then
    track.output = "internal"
  elseif track.output == "internal" then
    track.output = "off"
  else
    track.output = "midi"
  end
end

-- Set all output channels for a track
function Sequencer:set_all_channels(track_idx)
  local track = self.tracks[track_idx]
  if not track then return end
  if #track.out_channels == 16 then
    -- Toggle back to original channel
    track.out_channels = {track.source_ch}
  else
    local chs = {}
    for i = 1, 16 do chs[i] = i end
    track.out_channels = chs
  end
end

-- Reassign output channels on current tracks (after channel config change)
function Sequencer:reassign_channels()
  TrackAssign.reassign_channels(self.tracks)
end

function Sequencer:track_count()
  return #self.tracks
end

return Sequencer
