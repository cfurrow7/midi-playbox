-- MIDI PLAYBOX
-- 4-track MIDI song player with built-in drum machine
-- 3 synth tracks (bass/chords/lead) -> MIDI out
-- 1 drum track -> internal synthesized drums (808/707/606/DrumTraks)
--
-- E1: page select | E2/E3: context-sensitive
-- K2: play/stop (page 1) | K3: restart (page 1)
--
-- v0.1 @clf

engine.name = "DrumBox"

local Sequencer = include("midi-playbox/lib/sequencer")
local Queue = include("midi-playbox/lib/queue")
local UILib = include("midi-playbox/lib/ui")

local seq = Sequencer.new()
local queue = Queue.new()
local ui
local state = {}

local MIDI_DIR = _path.code .. "midi-playbox/midi"
local PLAYLIST_DIR = _path.code .. "midi-playbox/playlists"

local redraw_clock = nil

function init()
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

  -- MIDI connection
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
    -- Auto-advance queue
    advance_queue()
  end

  seq.on_progress = function(elapsed, duration)
    -- Triggers redraw via clock
  end

  -- Add params
  params:add_separator("MIDI PLAYBOX")

  params:add_number("midi_device", "MIDI Device", 1, 16, 1)
  params:set_action("midi_device", function(val)
    seq:connect_midi(val)
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

  -- Load playlists if any exist
  check_playlists()

  -- Redraw clock (10 fps)
  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1/10)
      ui:decay_flash()
      redraw()
    end
  end)

  print("MIDI PLAYBOX loaded")
  print("MIDI dir: " .. MIDI_DIR)
  print("Files found: " .. #ui.lib_files)
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
        -- Auto-load first playlist found
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
  seq:stop()
end
