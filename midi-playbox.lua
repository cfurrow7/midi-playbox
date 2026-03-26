-- MIDI JUKEBOX
-- Dynamic track MIDI song player with built-in drum machine
-- Auto-assigns MIDI channels to roles (bass/chord/lead/drum/fx)
-- Drum tracks -> sample-based drums (808/909/606/LinnDrum/DMX) with LPF + delay
-- Synth tracks -> MIDI out, or nb voice (Doubledecker, MollyThePoly, etc.)
-- AKAI MIDIMIX support for hands-on control
--
-- E1: page select | E2/E3: context-sensitive
-- K2: play/stop (page 1) | K3: restart (page 1)
--
-- v1.3 @clf

engine.name = "DrumBox"

local nb = require("nb/lib/nb")
local Sequencer = include("midi-playbox/lib/sequencer")
local Queue = include("midi-playbox/lib/queue")
local UILib = include("midi-playbox/lib/ui")
local MidiMix = include("midi-playbox/lib/midimix")
local TrackAssign = include("midi-playbox/lib/track_assign")
local DrumKits = include("midi-playbox/lib/drum_kits")

local seq = Sequencer.new()
local queue = Queue.new()
local midimix = MidiMix.new()
local ui
local state = {}

-- Max tracks with nb voice selectors
local MAX_NB_TRACKS = 8

-- Shared MIDI folder accessible by all Norns scripts
local MIDI_DIR = _path.data .. "midi"
local PLAYLIST_DIR = _path.code .. "midi-playbox/playlists"

local redraw_clock = nil

function init()
  -- Create shared MIDI folder if it doesn't exist
  os.execute("mkdir -p " .. MIDI_DIR)

  -- Init nb voice system
  nb:init()

  state.kit = 1  -- 808
  state.midi_dir = MIDI_DIR
  state.lock = false           -- when true, track settings persist across songs
  state.locked_settings = {}   -- saved per-track settings (by index)

  -- Callbacks for UI -> main script communication
  state.on_next = function()
    advance_queue()
  end

  state.on_load_current = function()
    load_current()
  end

  state.on_play_file = function(entry)
    -- Clear queue, add just this file, play
    queue:clear()
    queue:add(entry.display, entry.file)
    queue.position = 1
    load_current()
  end

  -- Init UI
  ui = UILib.new(seq, queue, state)
  ui:refresh_library(MIDI_DIR)

  -- MIDI out connection (for synths)
  seq:connect_midi(1)

  -- Load default drum kit samples
  DrumKits.load(1)  -- TR-808

  -- Send PC 0 (init patch) to all MIDI channels on startup
  if seq.midi_out then
    for ch = 1, 16 do
      seq.midi_out:program_change(0, ch)
    end
    print("Sent PC 0 to all MIDI channels")
  end

  -- Sequencer callbacks
  seq.on_note = function(track_idx, note, vel, drum_voice)
    ui:note_flash(track_idx)
    if drum_voice then
      ui:drum_voice_flash(drum_voice)
    end
  end

  seq.on_end = function()
    advance_queue()
  end

  seq.on_progress = function(elapsed, duration)
    -- Triggers redraw via clock
  end

  -- ===== PARAMS =====
  params:add_separator("MIDI JUKEBOX")

  params:add_number("midi_out_device", "MIDI Out Device", 1, 16, 1)
  params:set_action("midi_out_device", function(val)
    seq:connect_midi(val)
  end)

  params:add_number("midimix_device", "MIDIMIX Device", 1, 16, 2)
  params:set_action("midimix_device", function(val)
    midimix:connect(val)
  end)

  params:add_option("drum_kit", "Drum Kit", DrumKits.names(), 1)
  params:set_action("drum_kit", function(val)
    state.kit = val
    DrumKits.load(val)
  end)

  params:add_separator("DRUM FX")

  params:add_control("drum_lpf", "Drum LPF", controlspec.new(20, 20000, "exp", 0, 20000, "Hz"))
  params:set_action("drum_lpf", function(val)
    engine.lpf(val)
  end)

  params:add_control("drum_res", "Drum Resonance", controlspec.new(0.05, 1.0, "lin", 0, 0.3))
  params:set_action("drum_res", function(val)
    engine.res(val)
  end)

  params:add_control("delay_time", "Delay Time", controlspec.new(0.01, 2.0, "exp", 0, 0.3, "s"))
  params:set_action("delay_time", function(val)
    engine.delay_time(val)
  end)

  params:add_control("delay_feedback", "Delay Feedback", controlspec.new(0, 0.95, "lin", 0, 0.3))
  params:set_action("delay_feedback", function(val)
    engine.delay_feedback(val)
  end)

  params:add_control("delay_mix", "Delay Mix", controlspec.new(0, 1, "lin", 0, 0.0))
  params:set_action("delay_mix", function(val)
    engine.delay_mix(val)
  end)

  params:add_option("track_lock", "Track Lock", {"Off", "On"}, 1)
  params:set_action("track_lock", function(val)
    state.lock = (val == 2)
    if state.lock and #seq.tracks > 0 then
      save_track_settings()
    end
    print("Track Lock: " .. (state.lock and "ON" or "OFF"))
  end)

  params:add_separator("CHANNEL ROUTING")

  params:add_number("bass_ch", "Bass Ch", 1, 16, 2)
  params:set_action("bass_ch", function(val)
    TrackAssign.set_channel("bass", val)
    seq:reassign_channels()
  end)

  params:add_number("chord_ch", "Chord Ch", 1, 16, 4)
  params:set_action("chord_ch", function(val)
    TrackAssign.set_channel("chord", val)
    seq:reassign_channels()
  end)

  params:add_number("lead_ch", "Lead Ch", 1, 16, 3)
  params:set_action("lead_ch", function(val)
    TrackAssign.set_channel("lead", val)
    seq:reassign_channels()
  end)

  params:add_number("drum_ch", "Drum Ch", 1, 16, 15)
  params:set_action("drum_ch", function(val)
    TrackAssign.set_channel("drum", val)
    seq:reassign_channels()
  end)

  -- ===== NB VOICES (per track) =====
  params:add_separator("TRACK VOICES")

  for i = 1, MAX_NB_TRACKS do
    nb:add_param("track_" .. i .. "_voice", "Track " .. i .. " Voice")
  end
  nb:add_player_params()

  params:add_separator("MIDI FILTER")

  params:add_option("quantize", "Quantize", {"Off", "1/4", "1/8", "1/16", "1/32"}, 4)
  params:set_action("quantize", function(val)
    local divs = {0, 4, 8, 16, 32}
    seq.quantize_div = divs[val]
    seq:rebuild_timeline()
  end)

  params:add_number("min_velocity", "Min Velocity", 0, 60, 15)
  params:set_action("min_velocity", function(val)
    seq.min_velocity = val
    seq:rebuild_timeline()
  end)

  params:add_option("min_duration", "Min Duration", {"Off", "25ms", "50ms", "100ms"}, 3)
  params:set_action("min_duration", function(val)
    local durs = {0, 0.025, 0.05, 0.1}
    seq.min_duration = durs[val]
    seq:rebuild_timeline()
  end)

  -- ===== MIDIMIX SETUP =====
  setup_midimix()

  -- Load playlists if any exist
  check_playlists()

  -- Redraw clock (10 fps)
  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1/10)
      ui:decay_flash()
      midimix:update_leds(seq.tracks)
      redraw()
    end
  end)

  print("MIDI JUKEBOX v1.3 loaded (sample drums + nb voices)")
  print("MIDI dir: " .. MIDI_DIR)
  print("Files found: " .. #ui.lib_files)
end

-- Get nb player for a track (returns nil if not set to nb)
function get_nb_player(track_idx)
  if track_idx < 1 or track_idx > MAX_NB_TRACKS then return nil end
  local p = params:lookup_param("track_" .. track_idx .. "_voice")
  if p then return p:get_player() end
  return nil
end

function setup_midimix()
  -- Connect MIDIMIX (default device 2, configurable via params)
  midimix:connect(2)

  -- Faders 1-8: velocity scaling per track
  midimix.on_velocity = function(track_idx, vel)
    local track = seq.tracks[track_idx]
    if not track then return end
    track.velocity_scale = vel
    if track.output == "internal" then
      engine.amp(vel)
    end
    midimix:update_leds(seq.tracks)
  end

  -- Knob Row 1 (1-8): MIDI output channel per track
  -- ch 1-15 = MIDI out, ch 16 = nb voice (from params)
  midimix.on_channel = function(track_idx, ch)
    local track = seq.tracks[track_idx]
    if not track then return end
    if track.role == "drum" then return end  -- drums stay internal
    if ch == 16 then
      track.output = "nb"
      track.out_channels = {0}
      print("Track " .. track_idx .. " -> nb voice")
    else
      track.output = "midi"
      track.out_channels = {ch}
    end
  end

  -- Knob Row 2 (1-7): Program Change per track
  midimix.on_program_change = function(track_idx, pc)
    local track = seq.tracks[track_idx]
    if not track then return end
    if track.output == "midi" and seq.midi_out then
      for _, ch in ipairs(track.out_channels or {}) do
        seq.midi_out:program_change(pc, ch)
      end
    end
  end

  -- Knob Row 2 (8): drum LPF filter
  midimix.on_filter = function(freq)
    ui.filter_freq = freq
    engine.lpf(freq)
  end

  -- Knob Row 1 (8): delay send/mix
  midimix.on_delay_mix = function(mix)
    engine.delay_mix(mix)
    params:set("delay_mix", mix)
  end

  -- Knob Row 3 (8): delay time
  midimix.on_delay_time = function(time)
    engine.delay_time(time)
    params:set("delay_time", time)
  end

  -- Mute buttons: toggle track mute by index
  midimix.on_mute_toggle = function(track_idx)
    seq:toggle_mute(track_idx)
  end

  -- Rec buttons: toggle nb voice mode
  midimix.on_all_toggle = function(track_idx)
    local track = seq.tracks[track_idx]
    if not track then return end
    if track.role == "drum" then return end
    if track.output == "nb" then
      -- Toggle back to MIDI
      track.output = "midi"
      seq:reassign_channels()
      print("Track " .. track_idx .. " -> MIDI ch " .. (track.out_channels[1] or "?"))
    else
      -- Switch to nb
      track.output = "nb"
      print("Track " .. track_idx .. " -> nb voice")
    end
    midimix:update_leds(seq.tracks)
  end

  -- Bank buttons: prev/next song
  midimix.on_prev_song = function()
    if queue.position > 1 then
      queue.position = queue.position - 1
      load_current()
    end
  end

  midimix.on_next_song = function()
    advance_queue()
  end

  -- Master fader = BPM (debounced to avoid stop/rebuild spam)
  local bpm_pending = nil
  local bpm_clock = nil
  midimix.on_bpm = function(bpm)
    bpm_pending = bpm
    if bpm_clock then clock.cancel(bpm_clock) end
    bpm_clock = clock.run(function()
      clock.sleep(0.15)
      if bpm_pending then
        print("BPM: " .. bpm_pending)
        seq:set_bpm(bpm_pending)
        bpm_pending = nil
        bpm_clock = nil
      end
    end)
  end

  -- SEND ALL button (above master fader) = PANIC
  midimix.on_panic = function()
    print("PANIC! All notes off")
    seq:stop()
    seq:all_notes_off()
  end
end

-- Save current track settings for LOCK (by role, so it adapts to different songs)
function save_track_settings()
  state.locked_settings = {}
  -- Save per-role settings (first track of each role wins)
  for i, track in ipairs(seq.tracks) do
    local role = track.role
    if not state.locked_settings[role] then
      state.locked_settings[role] = {
        output = track.output,
        out_channels = {table.unpack(track.out_channels or {})},
        velocity_scale = track.velocity_scale,
        mute = track.mute,
      }
    end
  end
  -- Also save by index (for MIDIMIX fader positions)
  for i, track in ipairs(seq.tracks) do
    state.locked_settings[i] = {
      velocity_scale = track.velocity_scale,
      mute = track.mute,
    }
  end
  local roles = {}
  for k, _ in pairs(state.locked_settings) do
    if type(k) == "string" then table.insert(roles, k) end
  end
  print("LOCK: saved settings for roles: " .. table.concat(roles, ", "))
end

-- Apply locked settings to current tracks (role-based: bass->bass, chord->chord, etc.)
function apply_locked_settings()
  if not state.lock or not next(state.locked_settings) then return end
  for i, track in ipairs(seq.tracks) do
    local role_settings = state.locked_settings[track.role]
    local idx_settings = state.locked_settings[i]
    if role_settings then
      track.output = role_settings.output
      track.out_channels = {table.unpack(role_settings.out_channels)}
    end
    if idx_settings then
      track.velocity_scale = idx_settings.velocity_scale
      track.mute = idx_settings.mute
    end
  end
  print("LOCK: applied role-based settings to " .. #seq.tracks .. " tracks")
end

function load_current()
  local song = queue:current()
  if not song then return end

  -- Save settings before loading if locked
  if state.lock and #seq.tracks > 0 then
    save_track_settings()
  end

  seq:stop()
  local ok, err = seq:load(song.file)
  if ok then
    -- Reapply locked settings to the new tracks
    apply_locked_settings()
    print("Loaded: " .. song.name .. " (" .. seq:get_bpm() .. " BPM, " .. seq:track_count() .. " tracks)" .. (state.lock and " [LOCKED]" or ""))
    seq:play()
  else
    print("Error loading " .. song.name .. ": " .. (err or "unknown"))
  end
end

function advance_queue()
  local next_song = queue:advance()
  if next_song then
    load_current()
  else
    print("Queue finished")
  end
end

function check_playlists()
  local files = util.scandir(PLAYLIST_DIR)
  if files then
    for _, f in ipairs(files) do
      if f:match("%.txt$") then
        print("Found playlist: " .. f)
        if queue:count() == 0 then
          local ok = queue:load_playlist(PLAYLIST_DIR .. "/" .. f, MIDI_DIR)
          if ok then
            print("Loaded playlist: " .. f .. " (" .. queue:count() .. " songs)")
          end
        end
      end
    end
  end
end

function redraw()
  if ui then ui:draw() end
end

function enc(n, d)
  if ui then
    ui:enc(n, d)
    redraw()
  end
end

function key(n, z)
  if ui then
    ui:key(n, z)
    redraw()
  end
end

function cleanup()
  if redraw_clock then clock.cancel(redraw_clock) end
  midimix:leds_off()
  seq:stop()
end
