-- MIDI PLAYBOX
-- 4-track MIDI song player with built-in drum machine
-- 3 synth tracks (bass/chords/lead) -> MIDI out
-- 1 drum track -> internal synthesized drums (808/707/606/DrumTraks)
-- AKAI MIDIMIX support for hands-on control
--
-- E1: page select | E2/E3: context-sensitive
-- K2: play/stop (page 1) | K3: restart (page 1)
--
-- v0.2 @clf

engine.name = "DrumBox"

local Sequencer = include("midi-playbox/lib/sequencer")
local Queue = include("midi-playbox/lib/queue")
local UILib = include("midi-playbox/lib/ui")
local MidiMix = include("midi-playbox/lib/midimix")

local seq = Sequencer.new()
local queue = Queue.new()
local midimix = MidiMix.new()
local ui
local state = {}

-- Shared MIDI folder accessible by all Norns scripts
local MIDI_DIR = _path.data .. "midi"
local PLAYLIST_DIR = _path.code .. "midi-playbox/playlists"

local redraw_clock = nil

function init()
  -- Create shared MIDI folder if it doesn't exist
  os.execute("mkdir -p " .. MIDI_DIR)

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

  -- Sequencer callbacks
  seq.on_note = function(track, note, vel, drum_voice)
    ui:note_flash(track)
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
  params:add_separator("MIDI PLAYBOX")

  params:add_number("midi_out_device", "MIDI Out Device", 1, 16, 1)
  params:set_action("midi_out_device", function(val)
    seq:connect_midi(val)
  end)

  params:add_number("midimix_device", "MIDIMIX Device", 1, 16, 2)
  params:set_action("midimix_device", function(val)
    midimix:connect(val)
  end)

  params:add_number("bass_ch", "Bass MIDI Ch", 1, 16, 1)
  params:set_action("bass_ch", function(val) seq.out_channels.bass = val end)

  params:add_number("chords_ch", "Chords MIDI Ch", 1, 16, 2)
  params:set_action("chords_ch", function(val) seq.out_channels.chords = val end)

  params:add_number("lead_ch", "Lead MIDI Ch", 1, 16, 3)
  params:set_action("lead_ch", function(val) seq.out_channels.lead = val end)

  params:add_option("drum_kit", "Drum Kit", {"808", "707", "606", "DrumTraks"}, 1)
  params:set_action("drum_kit", function(val)
    state.kit = val
    engine.kit(val - 1)
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
      midimix:update_leds(seq.mute)
      redraw()
    end
  end)

  print("MIDI PLAYBOX v0.2 loaded")
  print("MIDI dir: " .. MIDI_DIR)
  print("Files found: " .. #ui.lib_files)
end

function setup_midimix()
  -- Connect MIDIMIX (default device 2, configurable via params)
  midimix:connect(2)

  -- Faders 1-4: velocity scaling (down = quieter notes, 0 = silent)
  midimix.on_velocity = function(track, vel)
    print("FADER " .. track .. " = " .. string.format("%.2f", vel))
    seq.velocity_scale[track] = vel
    if track == "drum" then
      engine.amp(vel)
    end
  end

  -- Knob Row 1 (1-3): octave, (4): kit
  midimix.on_octave = function(track, octave)
    seq.octave[track] = octave
  end

  midimix.on_kit = function(kit_index)
    state.kit = kit_index
    engine.kit(kit_index - 1)
    params:set("drum_kit", kit_index)
  end

  -- Knob Row 2 (4): drum filter
  midimix.on_filter = function(freq)
    ui.filter_freq = freq
    engine.lpf(freq)
  end

  -- Knob Row 3 (4): drum random amount
  midimix.on_random_amt = function(amt)
    ui.random_amt = amt
    engine.random_amt(amt)
  end

  -- Mute buttons: toggle track mute
  midimix.on_mute_toggle = function(track)
    seq:toggle_mute(track)
  end

  -- Solo buttons: cycle source MIDI channel
  midimix.on_source_cycle = function(track)
    local available = seq:get_available_channels()
    if #available > 0 then
      local current = seq.assignment and seq.assignment[track] and seq.assignment[track].ch
      local next_idx = 1
      for i, ch in ipairs(available) do
        if ch == current then
          next_idx = (i % #available) + 1
          break
        end
      end
      seq:set_source_channel(track, available[next_idx])
    end
  end

  -- Master fader: BPM
  midimix.on_bpm = function(bpm)
    seq:set_bpm(bpm)
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
end

function load_current()
  local song = queue:current()
  if not song then return end

  seq:stop()
  local ok, err = seq:load(song.file)
  if ok then
    print("Loaded: " .. song.name .. " (" .. seq:get_bpm() .. " BPM)")
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
