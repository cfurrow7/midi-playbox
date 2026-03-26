-- drum_kits.lua: Sample kit definitions for DrumBox engine
-- Maps kit names to sample paths for 8 drum voices:
--   0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash
--
-- Paths relative to _path.dust (e.g. "audio/common/808/808-BD.wav")
-- Missing samples = nil (engine falls back to synthesis)

local DrumKits = {}

-- Voice slot names (for display/debug)
DrumKits.VOICE_NAMES = {"kick", "snare", "chh", "ohh", "clap", "ltom", "htom", "crash"}

-- Kit definitions
DrumKits.KITS = {
  {
    name = "TR-808",
    path = "audio/common/808/",
    samples = {
      "808-BD.wav",   -- 0: kick
      "808-SD.wav",   -- 1: snare
      "808-CH.wav",   -- 2: closed hat
      "808-OH.wav",   -- 3: open hat
      "808-CP.wav",   -- 4: clap
      "808-LT.wav",   -- 5: low tom
      "808-HT.wav",   -- 6: high tom
      "808-CY.wav",   -- 7: crash/cymbal
    }
  },
  {
    name = "TR-909",
    path = "audio/common/909/",
    samples = {
      "909-BD.wav",   -- 0: kick
      "909-SD.wav",   -- 1: snare
      "909-CH.wav",   -- 2: closed hat
      "909-OH.wav",   -- 3: open hat
      "909-CP.wav",   -- 4: clap
      nil,            -- 5: low tom (not in common/909)
      nil,            -- 6: high tom
      "909-CY.wav",   -- 7: crash/cymbal
    }
  },
  {
    name = "TR-606",
    path = "audio/common/606/",
    samples = {
      "606-BD.wav",   -- 0: kick
      "606-SD.wav",   -- 1: snare
      "606-CH.wav",   -- 2: closed hat
      "606-OH.wav",   -- 3: open hat
      nil,            -- 4: clap (not in 606)
      "606-LT.wav",   -- 5: low tom
      "606-HT.wav",   -- 6: high tom
      "606-CY.wav",   -- 7: crash/cymbal
    }
  },
  -- To add more kits: drop samples into audio/midi-playbox/<kit>/
  -- and add an entry here with 8 sample filenames (or nil for synthesis fallback)
}

-- Load a kit by index (1-based) into the DrumBox engine
function DrumKits.load(kit_idx)
  local kit = DrumKits.KITS[kit_idx]
  if not kit then
    print("DrumKits: invalid kit index " .. tostring(kit_idx))
    return false
  end

  print("DrumKits: loading " .. kit.name)
  for voice = 0, 7 do
    local sample = kit.samples[voice + 1]
    if sample then
      local full_path = _path.dust .. kit.path .. sample
      if util.file_exists(full_path) then
        engine.load_sample(voice, full_path)
      else
        print("  voice " .. voice .. " (" .. DrumKits.VOICE_NAMES[voice + 1] .. "): MISSING " .. full_path)
      end
    end
  end
  return true
end

-- Get kit names as a table (for params:add_option)
function DrumKits.names()
  local n = {}
  for _, kit in ipairs(DrumKits.KITS) do
    table.insert(n, kit.name)
  end
  return n
end

return DrumKits
