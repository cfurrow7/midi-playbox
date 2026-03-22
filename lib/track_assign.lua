-- track_assign.lua: Auto-assign MIDI file channels to roles
-- Dynamic track count - creates a track per active channel
-- Ported from Play My Synths logic

local TrackAssign = {}

-- Role detection patterns (from PMS)
local role_patterns = {
  drum = { "drum", "perc", "kit", "beat", "cymbal", "snare", "kick", "hat" },
  bass = { "bass" },
  lead = { "lead", "melody", "solo", "vocal", "voice", "flute", "trumpet", "sax", "whistle" },
  chord = { "chord", "pad", "organ", "piano", "key", "string", "acoustic", "rhythm", "guitar", "harp" },
  fx = { "fx", "effect", "noise", "texture", "arp" },
}

-- GM drum note to voice mapping (8 voices)
-- 0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash
TrackAssign.gm_drum_map = {
  [35] = 0, [36] = 0,
  [38] = 1, [40] = 1, [37] = 1,
  [42] = 2, [44] = 2,
  [46] = 3,
  [39] = 4, [54] = 4,
  [41] = 5, [43] = 5, [45] = 5,
  [47] = 6, [48] = 6, [50] = 6,
  [49] = 7, [51] = 3, [52] = 7,
  [53] = 3, [55] = 7, [56] = 7, [57] = 7,
  [59] = 3,
}

for n = 58, 81 do
  if not TrackAssign.gm_drum_map[n] then
    TrackAssign.gm_drum_map[n] = 7
  end
end

-- Guess role from track name
local function guess_role(name)
  if not name then return nil end
  local lower = string.lower(name)
  for role, patterns in pairs(role_patterns) do
    for _, pat in ipairs(patterns) do
      if string.find(lower, pat, 1, true) then
        return role
      end
    end
  end
  return nil
end

-- Guess role from note range
local function guess_role_from_range(ch_info)
  if ch_info.max_note <= 55 then
    return "bass"
  elseif ch_info.min_note >= 60 then
    return "lead"
  else
    return "chord"
  end
end

-- Build track list from parsed MIDI channel data
-- Returns array of track objects sorted by note count (most first)
function TrackAssign.build_tracks(ch_data)
  local tracks = {}

  -- Create a track per active channel
  for ch, info in pairs(ch_data) do
    local role
    if ch == 10 then
      role = "drum"
    else
      role = guess_role(info.name)
      if not role then
        role = guess_role_from_range(info)
      end
    end

    table.insert(tracks, {
      source_ch = ch,
      name = info.name or ("Ch " .. ch),
      role = role or "chord",
      output = (ch == 10) and "internal" or "midi",  -- drums default to internal engine
      out_channels = {ch},  -- default: same channel out
      octave = 0,
      velocity_scale = 1.0,
      mute = false,
      note_count = info.note_count,
      min_note = info.min_note,
      max_note = info.max_note,
    })
  end

  -- Sort by note count (most notes first, like PMS)
  table.sort(tracks, function(a, b)
    -- Drums always last
    if a.role == "drum" and b.role ~= "drum" then return false end
    if a.role ~= "drum" and b.role == "drum" then return true end
    return a.note_count > b.note_count
  end)

  return tracks
end

-- Map a GM drum note to a drum voice (0-7), or nil if not mapped
function TrackAssign.map_drum_note(note)
  return TrackAssign.gm_drum_map[note]
end

-- Short role label for display
function TrackAssign.role_label(role)
  local labels = {
    drum = "DRM",
    bass = "BAS",
    lead = "LED",
    chord = "CHD",
    fx = "FX",
  }
  return labels[role] or "???"
end

return TrackAssign
