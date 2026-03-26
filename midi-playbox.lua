-- MIDI JUKEBOX
-- Dynamic track MIDI song player with built-in drum machine
-- Auto-assigns MIDI channels to roles (bass/chord/lead/drum/fx)
-- Drum tracks -> internal synthesized drums (808/707/606/DrumTraks)
-- Synth tracks -> MIDI out, or nb voice (Doubledecker, MollyThePoly, etc.)
-- AKAI MIDIMIX support for hands-on control
--
-- E1: page select | E2/E3: context-sensitive
-- K2: play/stop (page 1) | K3: restart (page 1)
--
-- v1.2 @clf

engine.name = "DrumBox"

local nb = require("nb/lib/nb")
local Sequencer = include("midi-playbox/lib/sequencer")
local Queue = include("midi-playbox/lib/queue")
local UILib = include("midi-playbox/lib/ui")
local MidiMix = include("midi-playbox/lib/midimix")
local TrackAssign = include("midi-playbox/lib/track_assign")

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

  -- Set default drum kit
  engine.kit(0)  -- 808

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

  params:add_option("drum_kit", "Drum Kit", {"808", "707", "606", "DrumTraks"}, 1)
  params:set_action("drum_kit", function(val)
    state.kit = val
    engine.kit(val - 1)
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

  params:add_number("lead_ch", "Lead Ch", 1, 16, 10)
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

  print("MIDI JUKEBOX v1.2 loaded (nb voices enabled)")
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

  -- Knob Row 3 (8): drum resonance
  midimix.on_resonance = function(res)
    ui.filter_res = res
    engine.res(res)
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

function load_current()
  local song = queue:current()
  if not song then return end

  seq:stop()
  local ok, err = seq:load(song.file)
  if ok then
    print("Loaded: " .. song.name .. " (" .. seq:get_bpm() .. " BPM, " .. seq:track_count() .. " tracks)")
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
