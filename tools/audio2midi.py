#!/usr/bin/env python3
"""audio2midi: Convert audio files to multi-track MIDI

Pipeline:
  1. Detect BPM from original audio
  2. Demucs separates audio into stems (bass, drums, vocals, other)
  3. basic-pitch converts each stem to MIDI
  4. Quantize notes to nearest grid position
  5. Remap drum notes to GM standard
  6. Stems merged into a single multi-track MIDI file

Usage:
  python3 audio2midi.py song.mp3
  python3 audio2midi.py song.mp3 -o output.mid
  python3 audio2midi.py song.mp3 --bpm 122         # override BPM detection
  python3 audio2midi.py song.mp3 --quantize 8       # quantize to 8th notes (default: 16th)
  python3 audio2midi.py song.mp3 --no-quantize      # skip quantization
  python3 audio2midi.py song.mp3 --stems-only       # just separate, no MIDI conversion
  python3 audio2midi.py song.mp3 --keep-stems       # keep intermediate WAV stems

Requirements:
  pip install demucs basic-pitch mido librosa
"""

import argparse
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def check_deps():
    """Check that required packages are installed."""
    missing = []
    for pkg, pip_name in [("demucs", "demucs"), ("basic_pitch", "basic-pitch"),
                           ("mido", "mido"), ("librosa", "librosa")]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pip_name)
    if missing:
        print(f"Missing packages: {', '.join(missing)}")
        print(f"Install with: pip install {' '.join(missing)}")
        sys.exit(1)


def detect_bpm(audio_path):
    """Detect BPM from audio using librosa."""
    import librosa
    print("Detecting BPM...")
    y, sr = librosa.load(str(audio_path), sr=22050, mono=True, duration=60)
    tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
    bpm = float(tempo[0]) if hasattr(tempo, '__len__') else float(tempo)
    # Round to nearest integer
    bpm = round(bpm)
    print(f"  Detected BPM: {bpm}")
    return bpm


def separate_stems(audio_path, output_dir, model="htdemucs"):
    """Run Demucs to split audio into stems."""
    print(f"Separating stems with {model}...")
    cmd = [
        sys.executable, "-m", "demucs",
        "-n", model,
        "-o", str(output_dir),
        str(audio_path)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Demucs error: {result.stderr}")
        sys.exit(1)

    song_name = Path(audio_path).stem
    stems_dir = output_dir / model / song_name
    if not stems_dir.exists():
        print(f"Stems not found at {stems_dir}")
        sys.exit(1)

    stems = {}
    for stem_file in stems_dir.glob("*.wav"):
        stem_name = stem_file.stem
        stems[stem_name] = stem_file
        print(f"  {stem_name}: {stem_file.name}")

    return stems


def get_model_path():
    """Get the basic-pitch model path, preferring ONNX over TF."""
    import basic_pitch
    model_dir = Path(basic_pitch.__file__).parent / "saved_models" / "icassp_2022"
    for ext in ["nmp.onnx", "nmp.tflite", "nmp"]:
        p = model_dir / ext
        if p.exists():
            return p
    from basic_pitch import ICASSP_2022_MODEL_PATH
    return ICASSP_2022_MODEL_PATH


def stem_to_midi(stem_path, output_path, stem_name):
    """Convert a single audio stem to MIDI using basic-pitch."""
    from basic_pitch.inference import predict_and_save

    print(f"  Converting {stem_name} to MIDI...")

    output_dir = output_path.parent
    model_path = get_model_path()
    predict_and_save(
        audio_path_list=[stem_path],
        output_directory=output_dir,
        save_midi=True,
        sonify_midi=False,
        save_model_outputs=False,
        save_notes=False,
        model_or_model_path=model_path,
        onset_threshold=0.5,
        frame_threshold=0.3,
        minimum_note_length=58,
    )

    bp_output = output_dir / f"{stem_path.stem}_basic_pitch.mid"
    if bp_output.exists():
        final = output_dir / f"{stem_name}.mid"
        bp_output.rename(final)
        return final
    return None


def drums_to_midi(stem_path, output_path):
    """Convert drum stem to MIDI using basic-pitch with relaxed thresholds."""
    from basic_pitch.inference import predict_and_save

    print("  Converting drums to MIDI...")

    output_dir = output_path.parent
    model_path = get_model_path()
    predict_and_save(
        audio_path_list=[stem_path],
        output_directory=output_dir,
        save_midi=True,
        sonify_midi=False,
        save_model_outputs=False,
        save_notes=False,
        model_or_model_path=model_path,
        onset_threshold=0.3,
        frame_threshold=0.2,
        minimum_note_length=30,
    )

    bp_output = output_dir / f"{stem_path.stem}_basic_pitch.mid"
    if bp_output.exists():
        final = output_dir / "drums.mid"
        bp_output.rename(final)
        return final
    return None


def quantize_track(track, ticks_per_beat, grid_division=16):
    """Quantize note events to the nearest grid position.

    grid_division: notes per beat (16 = 16th notes, 8 = 8th notes, 4 = quarter)
    """
    import mido

    grid_ticks = ticks_per_beat * 4 // grid_division  # ticks per grid unit

    new_track = mido.MidiTrack()
    abs_time = 0
    events = []

    # Convert delta times to absolute times
    for msg in track:
        abs_time += msg.time
        events.append((abs_time, msg))

    # Quantize note_on and note_off to grid
    quantized = []
    for abs_t, msg in events:
        if msg.type in ('note_on', 'note_off'):
            snapped = round(abs_t / grid_ticks) * grid_ticks
            quantized.append((snapped, msg))
        elif msg.is_meta or msg.type == 'control_change':
            quantized.append((abs_t, msg))
        else:
            # pitchwheel etc - snap to same grid
            snapped = round(abs_t / grid_ticks) * grid_ticks
            quantized.append((snapped, msg))

    # Sort by time (stable sort preserves order of simultaneous events)
    quantized.sort(key=lambda x: x[0])

    # Convert back to delta times
    prev_time = 0
    for abs_t, msg in quantized:
        delta = max(0, abs_t - prev_time)
        new_track.append(msg.copy(time=delta))
        prev_time = abs_t

    return new_track


def remap_drum_notes(track):
    """Remap basic-pitch's arbitrary drum notes to GM drum standard.

    basic-pitch detects pitched frequencies in drum sounds, so kicks
    end up as low notes, hats as high notes, etc. We map by pitch range
    to GM drum note numbers.
    """
    import mido

    # Pitch range to GM drum note mapping
    # basic-pitch puts kicks ~28-40, snares ~40-55, hats ~55-75, crashes ~75+
    def to_gm_drum(note):
        if note <= 35:
            return 36   # GM kick
        elif note <= 45:
            return 38   # GM snare
        elif note <= 55:
            return 42   # GM closed hi-hat
        elif note <= 65:
            return 46   # GM open hi-hat
        elif note <= 75:
            return 49   # GM crash
        else:
            return 51   # GM ride

    new_track = mido.MidiTrack()
    for msg in track:
        if msg.type in ('note_on', 'note_off'):
            new_note = to_gm_drum(msg.note)
            new_track.append(msg.copy(note=new_note))
        else:
            new_track.append(msg.copy())

    return new_track


def filter_weak_notes(track, velocity_threshold=30):
    """Remove ghost notes below velocity threshold."""
    import mido
    new_track = mido.MidiTrack()
    # Track which notes we're keeping so we can also keep their note_offs
    active = set()

    for msg in track:
        if msg.type == 'note_on' and msg.velocity > 0:
            if msg.velocity >= velocity_threshold:
                active.add(msg.note)
                new_track.append(msg.copy())
            else:
                # Ghost note - skip but preserve timing
                new_track.append(mido.Message('note_on', note=0, velocity=0,
                                              channel=msg.channel, time=msg.time))
        elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
            if msg.note in active:
                active.discard(msg.note)
                new_track.append(msg.copy())
            else:
                new_track.append(mido.Message('note_on', note=0, velocity=0,
                                              channel=msg.channel, time=msg.time))
        else:
            new_track.append(msg.copy())

    return new_track


def deduplicate_chord_notes(track, ticks_per_beat, window_ticks=None):
    """Within each chord window, keep only the strongest notes.

    For chords: if multiple notes fire within a small window,
    keep the top 4 by velocity (typical chord = 3-4 notes).
    """
    import mido

    if window_ticks is None:
        window_ticks = ticks_per_beat // 8  # 32nd note window

    # Convert to absolute time events
    events = []
    abs_time = 0
    for msg in track:
        abs_time += msg.time
        events.append((abs_time, msg))

    # Group note_on events into chord windows
    note_ons = [(t, msg) for t, msg in events if msg.type == 'note_on' and msg.velocity > 0]
    notes_to_remove = set()

    i = 0
    while i < len(note_ons):
        # Collect all notes within window
        window_start = note_ons[i][0]
        cluster = [i]
        j = i + 1
        while j < len(note_ons) and note_ons[j][0] - window_start <= window_ticks:
            cluster.append(j)
            j += 1

        if len(cluster) > 4:
            # Sort by velocity, keep top 4
            by_vel = sorted(cluster, key=lambda idx: note_ons[idx][1].velocity, reverse=True)
            for idx in by_vel[4:]:
                notes_to_remove.add(id(note_ons[idx][1]))

        i = j if j > i + 1 else i + 1

    # Rebuild track without removed notes
    removed_notes = set()
    new_track = mido.MidiTrack()
    prev_time = 0
    for abs_t, msg in events:
        if id(msg) in notes_to_remove:
            removed_notes.add(msg.note)
            continue
        if (msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0)):
            if msg.note in removed_notes:
                removed_notes.discard(msg.note)
                continue
        delta = max(0, abs_t - prev_time)
        new_track.append(msg.copy(time=delta))
        prev_time = abs_t

    return new_track


def merge_stems_to_midi(stem_midis, output_path, bpm, quantize_div=16):
    """Merge individual stem MIDI files into a single multi-track MIDI."""
    import mido

    tpb = 480  # ticks per beat
    merged = mido.MidiFile(type=1, ticks_per_beat=tpb)

    # Tempo track
    tempo_track = mido.MidiTrack()
    tempo_track.append(mido.MetaMessage('set_tempo', tempo=mido.bpm2tempo(bpm), time=0))
    merged.tracks.append(tempo_track)

    # Channel assignments (0-indexed for mido)
    channel_map = {
        "bass": 1,      # ch 2
        "other": 3,     # ch 4 (chords)
        "vocals": 2,    # ch 3 (lead)
        "drums": 9,     # ch 10 (GM drums)
    }

    role_names = {
        "bass": "Bass",
        "other": "Chords",
        "vocals": "Lead",
        "drums": "Drums",
    }

    for stem_name, midi_path in stem_midis.items():
        if midi_path is None or not midi_path.exists():
            continue

        src = mido.MidiFile(midi_path)
        channel = channel_map.get(stem_name, 0)
        track_name = role_names.get(stem_name, stem_name.title())
        is_drums = (stem_name == "drums")

        # basic-pitch outputs tempo at 120 BPM with its own ticks_per_beat.
        # We need to rescale tick values to match our target BPM and tpb.
        src_tpb = src.ticks_per_beat
        # basic-pitch uses 120 BPM internally, but absolute time in seconds
        # is what matters. We rescale ticks so that the same real-time position
        # maps to our BPM.
        # real_seconds = ticks / (src_tpb * (src_bpm/60))
        # new_ticks = real_seconds * (tpb * (bpm/60))
        # ratio = new_ticks / old_ticks = (tpb * bpm) / (src_tpb * 120)
        src_bpm = 120  # basic-pitch default
        tick_ratio = (tpb * bpm) / (src_tpb * src_bpm)

        for src_track in src.tracks:
            new_track = mido.MidiTrack()
            new_track.append(mido.MetaMessage("track_name", name=track_name, time=0))

            has_notes = False
            for msg in src_track:
                # Rescale time
                new_time = round(msg.time * tick_ratio)

                if msg.is_meta:
                    if msg.type == 'set_tempo':
                        continue  # skip basic-pitch tempo, we set our own
                    new_track.append(msg.copy(time=new_time))
                elif hasattr(msg, "channel"):
                    if msg.type in ('note_on', 'note_off'):
                        has_notes = True
                    new_track.append(msg.copy(channel=channel, time=new_time))
                else:
                    new_track.append(msg.copy(time=new_time))

            if not has_notes:
                continue

            # Filter ghost notes
            new_track = filter_weak_notes(new_track, velocity_threshold=25)

            # Remap drum notes to GM
            if is_drums:
                new_track = remap_drum_notes(new_track)

            # Deduplicate chords (keep top 4 notes per cluster)
            if not is_drums:
                new_track = deduplicate_chord_notes(new_track, tpb)

            # Quantize
            if quantize_div > 0:
                new_track = quantize_track(new_track, tpb, quantize_div)

            merged.tracks.append(new_track)

    if len(merged.tracks) <= 1:  # only tempo track
        print("Warning: no MIDI data generated from any stem")
        return None

    merged.save(output_path)

    # Stats
    note_count = 0
    for track in merged.tracks:
        for msg in track:
            if msg.type == 'note_on' and msg.velocity > 0:
                note_count += 1

    print(f"\nSaved: {output_path}")
    print(f"  BPM: {bpm}")
    print(f"  Tracks: {len(merged.tracks) - 1}")  # minus tempo track
    print(f"  Notes: {note_count}")
    print(f"  Quantize: 1/{quantize_div} notes" if quantize_div > 0 else "  Quantize: off")
    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="Convert audio files to multi-track MIDI"
    )
    parser.add_argument("audio", help="Input audio file (mp3, wav, flac, etc)")
    parser.add_argument("-o", "--output", help="Output MIDI file path")
    parser.add_argument("--bpm", type=int, help="Override BPM (default: auto-detect)")
    parser.add_argument("--quantize", type=int, default=16,
                        help="Quantize grid (16=16th notes, 8=8th, 4=quarter, default: 16)")
    parser.add_argument("--no-quantize", action="store_true",
                        help="Skip quantization")
    parser.add_argument("--stems-only", action="store_true",
                        help="Only separate stems, don't convert to MIDI")
    parser.add_argument("--keep-stems", action="store_true",
                        help="Keep intermediate WAV stem files")
    parser.add_argument("--model", default="htdemucs",
                        help="Demucs model (default: htdemucs)")
    parser.add_argument("--stems-dir",
                        help="Directory for stem output (default: temp)")

    args = parser.parse_args()

    audio_path = Path(args.audio).resolve()
    if not audio_path.exists():
        print(f"File not found: {audio_path}")
        sys.exit(1)

    check_deps()

    song_name = audio_path.stem
    quantize_div = 0 if args.no_quantize else args.quantize

    # Output path
    if args.output:
        output_path = Path(args.output).resolve()
    else:
        output_path = audio_path.parent / f"{song_name}.mid"

    # Work directory for stems
    if args.stems_dir:
        work_dir = Path(args.stems_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        cleanup_work = False
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="audio2midi_"))
        cleanup_work = not args.keep_stems

    try:
        # Step 0: Detect BPM
        bpm = args.bpm or detect_bpm(audio_path)

        # Step 1: Separate stems
        stems = separate_stems(audio_path, work_dir, model=args.model)
        print(f"Separated {len(stems)} stems")

        if args.stems_only:
            if cleanup_work:
                dest = audio_path.parent / f"{song_name}_stems"
                dest.mkdir(exist_ok=True)
                for name, path in stems.items():
                    shutil.copy2(path, dest / f"{name}.wav")
                print(f"Stems saved to: {dest}")
            else:
                print(f"Stems at: {work_dir}")
            return

        # Step 2: Convert each stem to MIDI
        print("\nConverting stems to MIDI...")
        midi_dir = work_dir / "midi_stems"
        midi_dir.mkdir(exist_ok=True)

        stem_midis = {}
        for stem_name, stem_path in stems.items():
            if stem_name == "drums":
                result = drums_to_midi(stem_path, midi_dir / "drums.mid")
            else:
                result = stem_to_midi(stem_path, midi_dir / f"{stem_name}.mid", stem_name)
            stem_midis[stem_name] = result

        # Step 3: Merge, quantize, remap, and output
        print("\nMerging stems into multi-track MIDI...")
        merge_stems_to_midi(stem_midis, output_path, bpm, quantize_div)

    finally:
        if cleanup_work and work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
