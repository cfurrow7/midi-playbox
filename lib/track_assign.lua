-- track_assign.lua: Auto-assign MIDI file channels to roles (bass, chords, lead, drum)
-- Ported from Play My Synths logic

local TrackAssign = {}

-- Role detection patterns (from PMS)
local role_patterns = {
  drum = { "drum", "perc", "kit", "beat", "cymbal", "snare", "kick", "hat" },
  bass = { "bass" },
  lead = { "lead", "melody", "solo", "vocal", "voice", "flute", "trumpet", "sax", "whistle" },
  chord = { "chord", "pad", "organ", "piano", "key", "string", "acoustic", "rhythm", "guitar", "harp" },
}

-- GM drum note to voice mapping (8 voices)
-- 0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash
TrackAssign.gm_drum_map = {
  [35] = 0, [36] = 0,                       -- kick
  [38] = 1, [40] = 1, [37] = 1,             -- snare + rimshot
  [42] = 2, [44] = 2,                       -- closed hh
  [46] = 3,                                 -- open hh
  [39] = 4, [54] = 4,                       -- clap
  [41] = 5, [43] = 5, [45] = 5,             -- low tom
  [47] = 6, [48] = 6, [50] = 6,             -- high tom
  [49] = 7, [51] = 3, [52] = 7,             -- crash + ride(->ohh)
  [53] = 3, [55] = 7, [56] = 7, [57] = 7,  -- ride bell + cowbell + crash2
  [59] = 3,                                 -- ride 2
}

-- Extend drum map for remaining GM percussion
for n = 58, 81 do
  if not TrackAssign.gm_drum_map[n] then
    TrackAssign.gm_drum_map[n] = 7  -- misc percussion -> crash/perc voice
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

-- Guess role from note range (heuristic)
local function guess_role_from_range(ch_info)
  if ch_info.max_note <= 55 then
    return "bass"
  elseif ch_info.min_note >= 60 then
    return "lead"
  else
    return "chord"
  end
end

-- Auto-assign channels to 4 tracks
-- Returns: { bass = { ch=N, name=S }, chords = {...}, lead = {...}, drum = { ch=N } }
-- ch_data is the parsed.channels table from midi_parser
function TrackAssign.auto_assign(ch_data)
  local assignment = {
    bass = nil,
    chords = nil,
    lead = nil,
    drum = nil
  }

  -- Channel 10 is always drums (GM standard)
  if ch_data[10] then
    assignment.drum = { ch = 10, name = ch_data[10].name or "Drums" }
  end

  -- Sort remaining channels by note count (most notes first)
  local sorted = {}
  for ch, info in pairs(ch_data) do
    if ch ~= 10 then
      table.insert(sorted, { ch = ch, info = info })
    end
  end
  table.sort(sorted, function(a, b) return a.info.note_count > b.info.note_count end)

  -- First pass: assign by track name
  local used = {}
  for _, entry in ipairs(sorted) do
    local role = guess_role(entry.info.name)
    if role and role ~= "drum" and not assignment[role == "chord" and "chords" or role] then
      local key = role == "chord" and "chords" or role
      assignment[key] = { ch = entry.ch, name = entry.info.name or ("Ch " .. entry.ch) }
      used[entry.ch] = true
    end
  end

  -- Second pass: assign by note range
  for _, entry in ipairs(sorted) do
    if not used[entry.ch] then
      local role = guess_role_from_range(entry.info)
      local key = role == "chord" and "chords" or role
      if not assignment[key] then
        assignment[key] = { ch = entry.ch, name = entry.info.name or ("Ch " .. entry.ch) }
        used[entry.ch] = true
      end
    end
  end

  -- Third pass: fill remaining slots with whatever's left
  local slots = { "chords", "lead", "bass" }
  for _, entry in ipairs(sorted) do
    if not used[entry.ch] then
      for _, slot in ipairs(slots) do
        if not assignment[slot] then
          assignment[slot] = { ch = entry.ch, name = entry.info.name or ("Ch " .. entry.ch) }
          used[entry.ch] = true
          break
        end
      end
    end
  end

  -- If no drum channel found, check for channel with drum-like names
  if not assignment.drum then
    for _, entry in ipairs(sorted) do
      if not used[entry.ch] then
        local role = guess_role(entry.info.name)
        if role == "drum" then
          assignment.drum = { ch = entry.ch, name = entry.info.name or ("Ch " .. entry.ch) }
          used[entry.ch] = true
          break
        end
      end
    end
  end

  return assignment
end

-- Map a GM drum note to a drum voice (0-7), or nil if not mapped
function TrackAssign.map_drum_note(note)
  return TrackAssign.gm_drum_map[note]
end

return TrackAssign
