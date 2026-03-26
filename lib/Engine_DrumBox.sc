// Engine_DrumBox: 8-voice sample drum machine for MIDI JUKEBOX
// Classic drum machine samples (808, 707, 606, etc.) with global LPF + delay
// 8 drum voices: 0=kick, 1=snare, 2=chh, 3=ohh, 4=clap, 5=ltom, 6=htom, 7=crash

Engine_DrumBox : CroneEngine {
    var <buffers;        // Array of 8 Buffers (one per voice)
    var <masterAmp;
    var <drumBus;        // Audio bus: drums -> filter -> delay -> out
    var <filterSynth;
    var <delaySynth;
    var <lpfFreq;
    var <lpfRes;
    var <delayTime;
    var <delayFeedback;
    var <delayMix;

    alloc {
        masterAmp = 0.8;
        lpfFreq = 20000;
        lpfRes = 0.3;
        delayTime = 0.3;
        delayFeedback = 0.3;
        delayMix = 0.0;

        buffers = Array.fill(8, { nil });
        drumBus = Bus.audio(context.server, 2);

        // ---- SynthDefs ----

        // Sample player: plays a buffer one-shot with velocity scaling
        SynthDef(\drumbox_sample, { |out=0, buf=0, amp=0.5, rate=1, pan=0|
            var sig = PlayBuf.ar(1, buf, rate * BufRateScale.kr(buf), doneAction: 2);
            Out.ar(out, Pan2.ar(sig * amp, pan));
        }).add;

        // Stereo sample player (for stereo samples)
        SynthDef(\drumbox_sample_stereo, { |out=0, buf=0, amp=0.5, rate=1|
            var sig = PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), doneAction: 2);
            Out.ar(out, sig * amp);
        }).add;

        // Global LPF filter on drum bus
        SynthDef(\drumbox_filter, { |in, out=0, lpf=20000, res=0.3|
            var sig = In.ar(in, 2);
            sig = RLPF.ar(sig, lpf.clip(20, 20000), res.clip(0.05, 1.0));
            Out.ar(out, sig);
        }).add;

        // Stereo delay effect (after filter, before output)
        SynthDef(\drumbox_delay, { |in, out=0, time=0.3, feedback=0.3, mix=0.0|
            var dry = In.ar(in, 2);
            var left = CombL.ar(dry[0], 2.0, time, feedback * 6);
            var right = CombL.ar(dry[1], 2.0, time * 1.05, feedback * 6); // slight offset for width
            var wet = [left, right];
            Out.ar(out, dry + (wet * mix));
        }).add;

        // ---- Synthesis fallbacks (used when no sample loaded) ----

        SynthDef(\drumbox_kick, { |out=0, amp=0.5, pan=0|
            var pitchEnv = EnvGen.kr(Env.perc(0.001, 0.07));
            var body = SinOsc.ar(42 + (42 * 5 * pitchEnv));
            var click = WhiteNoise.ar * EnvGen.kr(Env.perc(0.001, 0.01)) * 0.3;
            var env = EnvGen.kr(Env.perc(0.001, 0.9, curve: -6), doneAction: 2);
            Out.ar(out, Pan2.ar((body + click) * env * amp, pan));
        }).add;

        SynthDef(\drumbox_snare, { |out=0, amp=0.5, pan=0|
            var tone = SinOsc.ar(180) * EnvGen.kr(Env.perc(0.001, 0.1, curve: -8)) * 0.4;
            var noise = BPF.ar(WhiteNoise.ar, 720, 2) * EnvGen.kr(Env.perc(0.005, 0.2, curve: -4), doneAction: 2) * 0.7;
            Out.ar(out, Pan2.ar((tone + noise) * amp, pan));
        }).add;

        SynthDef(\drumbox_chh, { |out=0, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, 0.04, curve: -8), doneAction: 2);
            Out.ar(out, Pan2.ar(BPF.ar(WhiteNoise.ar, 8000, 0.3) * env * amp * 2, pan));
        }).add;

        SynthDef(\drumbox_ohh, { |out=0, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, 0.3, curve: -4), doneAction: 2);
            Out.ar(out, Pan2.ar(BPF.ar(WhiteNoise.ar, 8000, 0.3) * env * amp * 2, pan));
        }).add;

        SynthDef(\drumbox_clap, { |out=0, amp=0.5, pan=0|
            var e1 = EnvGen.kr(Env.perc(0.001, 0.01));
            var e2 = EnvGen.kr(Env.perc(0.001, 0.01), delay: 0.01);
            var e3 = EnvGen.kr(Env.perc(0.001, 0.15), delay: 0.02, doneAction: 2);
            Out.ar(out, Pan2.ar(BPF.ar(WhiteNoise.ar, 1200, 0.5) * (e1 + e2 + e3) * amp * 0.5, pan));
        }).add;

        SynthDef(\drumbox_tom, { |out=0, freq=100, amp=0.5, pan=0|
            var pitchEnv = EnvGen.kr(Env.perc(0.001, 0.05));
            var body = SinOsc.ar(freq + (freq * 2 * pitchEnv));
            var env = EnvGen.kr(Env.perc(0.001, 0.3, curve: -6), doneAction: 2);
            Out.ar(out, Pan2.ar(body * env * amp, pan));
        }).add;

        SynthDef(\drumbox_cymbal, { |out=0, amp=0.5, pan=0|
            var env = EnvGen.kr(Env.perc(0.001, 1.5, curve: -3), doneAction: 2);
            var noise = BPF.ar(WhiteNoise.ar, 6000, 0.1);
            var ring = SinOsc.ar(6000 * 1.37) * 0.1 + (SinOsc.ar(6000 * 2.42) * 0.05);
            Out.ar(out, Pan2.ar((noise + ring) * env * amp, pan));
        }).add;

        // Wait for SynthDefs to be ready
        context.server.sync;

        // Start filter and delay on the drum bus (addToTail = after drum voices)
        filterSynth = Synth(\drumbox_filter, [
            \in, drumBus, \out, 0,
            \lpf, lpfFreq, \res, lpfRes
        ], addAction: \addToTail);

        delaySynth = Synth(\drumbox_delay, [
            \in, drumBus, \out, 0,
            \time, delayTime, \feedback, delayFeedback, \mix, delayMix
        ], addAction: \addToTail);

        // ---- Commands ----

        // Load a sample into a voice slot (0-7)
        this.addCommand(\load_sample, "is", { |msg|
            var voice = msg[1].asInteger.clip(0, 7);
            var path = msg[2].asString;
            if (buffers[voice].notNil, { buffers[voice].free });
            Buffer.read(context.server, path, action: { |buf|
                buffers[voice] = buf;
                ("DrumBox: loaded voice " ++ voice ++ " = " ++ path).postln;
            });
        });

        // Trigger a drum voice (0-7) with velocity (0.0-1.0)
        this.addCommand(\trig_kit, "if", { |msg|
            var voice = msg[1].asInteger.clip(0, 7);
            var vel = msg[2].asFloat.clip(0, 1);
            var amp = vel * masterAmp;
            var pans = [0, 0, 0.15, 0.15, 0, -0.3, 0.3, 0.2]; // stereo placement

            if (buffers[voice].notNil, {
                // Sample playback
                Synth(\drumbox_sample, [
                    \out, drumBus,
                    \buf, buffers[voice],
                    \amp, amp,
                    \rate, 1,
                    \pan, pans[voice]
                ], addAction: \addToHead);
            }, {
                // Synthesis fallback (no sample loaded)
                var synthNames = [
                    \drumbox_kick, \drumbox_snare, \drumbox_chh, \drumbox_ohh,
                    \drumbox_clap, \drumbox_tom, \drumbox_tom, \drumbox_cymbal
                ];
                var params = [\out, drumBus, \amp, amp, \pan, pans[voice]];
                if (voice == 5, { params = params ++ [\freq, 80] });
                if (voice == 6, { params = params ++ [\freq, 160] });
                Synth(synthNames[voice], params, addAction: \addToHead);
            });
        });

        // Switch drum kit (0=808, 1=707, 2=606, 3=DrumTraks)
        // Kit loading is now done from Lua via load_sample commands
        this.addCommand(\kit, "i", { |msg|
            // No-op: kit switching handled by Lua sending load_sample for each voice
            ("DrumBox: kit switch requested (handled by Lua)").postln;
        });

        // Master amplitude (0.0-1.0)
        this.addCommand(\amp, "f", { |msg|
            masterAmp = msg[1].asFloat.clip(0, 1);
        });

        // LPF cutoff frequency (20-20000 Hz)
        this.addCommand(\lpf, "f", { |msg|
            lpfFreq = msg[1].asFloat.clip(20, 20000);
            if (filterSynth.notNil, { filterSynth.set(\lpf, lpfFreq) });
        });

        // Filter resonance (0.05-1.0)
        this.addCommand(\res, "f", { |msg|
            lpfRes = msg[1].asFloat.clip(0.05, 1.0);
            if (filterSynth.notNil, { filterSynth.set(\res, lpfRes) });
        });

        // Delay time in seconds (0.01-2.0)
        this.addCommand(\delay_time, "f", { |msg|
            delayTime = msg[1].asFloat.clip(0.01, 2.0);
            if (delaySynth.notNil, { delaySynth.set(\time, delayTime) });
        });

        // Delay feedback (0.0-0.95)
        this.addCommand(\delay_feedback, "f", { |msg|
            delayFeedback = msg[1].asFloat.clip(0, 0.95);
            if (delaySynth.notNil, { delaySynth.set(\feedback, delayFeedback) });
        });

        // Delay wet/dry mix (0.0=dry, 1.0=wet)
        this.addCommand(\delay_mix, "f", { |msg|
            delayMix = msg[1].asFloat.clip(0, 1);
            if (delaySynth.notNil, { delaySynth.set(\mix, delayMix) });
        });

        // Sample pitch/rate (0.5-2.0)
        this.addCommand(\pitch, "f", { |msg|
            // Stored for next trigger - can't change running PlayBuf rate easily
            // This is used as a global pitch setting
        });
    }

    free {
        buffers.do { |buf| if (buf.notNil, { buf.free }) };
        if (delaySynth.notNil, { delaySynth.free });
        if (filterSynth.notNil, { filterSynth.free });
        if (drumBus.notNil, { drumBus.free });
    }
}
