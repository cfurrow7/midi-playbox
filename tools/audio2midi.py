#!/usr/bin/env python3
"""audio2midi: Convert audio files to multi-track MIDI

Pipeline:
  1. Demucs separates audio into stems (bass, drums, vocals, other)
  2. basic-pitch converts each stem to MIDI
  3. Stems merged into a single multi-track MIDI file

Usage:
  python3 audio2midi.py song.mp3
  python3 audio2midi.py song.mp3 -o output.mid
  python3 audio2midi.py song.mp3 --stems-only    # just separate, no MIDI conversion
  python3 audio2midi.py song.mp3 --keep-stems     # keep intermediate WAV stems

Requirements:
  pip install demucs basic-pitch mido
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def check_deps():
    """Check that required packages are installed."""
    missing = []
    try:
        import demucs  # noqa: F401
    except ImportError:
        missing.append("demucs")
    try:
        import basic_pitch  # noqa: F401
    except ImportError:
        missing.append("basic-pitch")
    try:
        import mido  # noqa: F401
    except ImportError:
        missing.append("mido")

    if missing:
        print(f"Missing packages: {', '.join(missing)}")
        print(f"Install with: pip install {' '.join(missing)}")
        sys.exit(1)


def separate_stems(audio_path, output_dir, model="htdemucs"):
    """Run Demucs to split audio into stems."""
    print(f"Separating stems with {model}...")
    cmd = [
        sys.executable, "-m", "demucs",
        "-n", model,
        "-o", str(output_dir),
        "--two-stems=vocals",  # first pass not needed, we use 4-stem
        str(audio_path)
    ]
    # Actually use the 4-stem default (bass, drums, vocals, other)
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

    # Find output stems
    song_name = Path(audio_path).stem
    stems_dir = output_dir / model / song_name
    if not stems_dir.exists():
        print(f"Stems not found at {stems_dir}")
        sys.exit(1)

    stems = {}
    for stem_file in stems_dir.glob("*.wav"):
        stem_name = stem_file.stem  # bass, drums, vocals, other
        stems[stem_name] = stem_file
        print(f"  {stem_name}: {stem_file.name}")

    return stems


def stem_to_midi(stem_path, output_path, stem_name):
    """Convert a single audio stem to MIDI using basic-pitch."""
    from basic_pitch.inference import predict_and_save

    print(f"  Converting {stem_name} to MIDI...")

    output_dir = output_path.parent
    # basic-pitch outputs to a directory with the input filename
    predict_and_save(
        audio_path_list=[stem_path],
        output_directory=output_dir,
        save_midi=True,
        save_model_outputs=False,
        save_notes=False,
        onset_threshold=0.5,
        frame_threshold=0.3,
        minimum_note_length=58,  # ms
    )

    # basic-pitch names output as <input_stem>_basic_pitch.mid
    bp_output = output_dir / f"{stem_path.stem}_basic_pitch.mid"
    if bp_output.exists():
        final = output_dir / f"{stem_name}.mid"
        bp_output.rename(final)
        return final
    return None


def drums_to_midi(stem_path, output_path):
    """Convert drum stem to MIDI.

    basic-pitch isn't great for drums (pitched note detection).
    We still run it but with lower thresholds to catch more hits.
    For better drum transcription, consider using madmom or onset detection.
    """
    from basic_pitch.inference import predict_and_save

    print("  Converting drums to MIDI (best effort - drums are tricky)...")

    output_dir = output_path.parent
    predict_and_save(
        audio_path_list=[stem_path],
        output_directory=output_dir,
        save_midi=True,
        save_model_outputs=False,
        save_notes=False,
        onset_threshold=0.3,  # lower threshold to catch more drum hits
        frame_threshold=0.2,
        minimum_note_length=30,
    )

    bp_output = output_dir / f"{stem_path.stem}_basic_pitch.mid"
    if bp_output.exists():
        final = output_dir / "drums.mid"
        bp_output.rename(final)
        return final
    return None


def merge_stems_to_midi(stem_midis, output_path, original_name):
    """Merge individual stem MIDI files into a single multi-track MIDI."""
    import mido

    merged = mido.MidiFile(type=1)

    # Channel assignments matching MIDI Jukebox expectations
    channel_map = {
        "bass": 2,
        "other": 4,    # chords/pads/etc
        "vocals": 3,   # melody/lead
        "drums": 9,    # GM drum channel (0-indexed = 9, 1-indexed = 10)
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
        channel = channel_map.get(stem_name, 1)
        track_name = role_names.get(stem_name, stem_name.title())

        for src_track in src.tracks:
            new_track = mido.MidiTrack()
            # Add track name
            new_track.append(mido.MetaMessage("track_name", name=track_name, time=0))

            for msg in src_track:
                if msg.is_meta:
                    new_track.append(msg)
                elif hasattr(msg, "channel"):
                    new_track.append(msg.copy(channel=channel))
                else:
                    new_track.append(msg)

            if len(new_track) > 1:  # more than just the name
                merged.tracks.append(new_track)

    if len(merged.tracks) == 0:
        print("Warning: no MIDI data generated from any stem")
        return None

    merged.save(output_path)
    print(f"\nSaved: {output_path}")
    print(f"  Tracks: {len(merged.tracks)}")
    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="Convert audio files to multi-track MIDI"
    )
    parser.add_argument("audio", help="Input audio file (mp3, wav, flac, etc)")
    parser.add_argument("-o", "--output", help="Output MIDI file path")
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
        # Step 1: Separate stems
        stems = separate_stems(audio_path, work_dir, model=args.model)
        print(f"Separated {len(stems)} stems")

        if args.stems_only:
            if cleanup_work:
                # Move stems to audio file's directory
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

        # Step 3: Merge into multi-track MIDI
        print("\nMerging stems into multi-track MIDI...")
        merge_stems_to_midi(stem_midis, output_path, song_name)

    finally:
        if cleanup_work and work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
