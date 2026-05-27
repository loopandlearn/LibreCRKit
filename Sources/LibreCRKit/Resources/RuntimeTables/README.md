# RuntimeTables

These `.bin` files are the bundled lookup tables for the white-box AES VM
(`CipherFn`) and the Phase 5 table-driven `lib_aes` primitive. The
`CipherFn` tables are distilled runtime artifacts from the clean-room research
corpus.

The `libaes_*.bin` files were extracted from static program regions after the
Python ports were validated bit-exact against instruction-emulator traces and
stored Phase 5 vectors. `libaes_5defec_round1_tables_26f621.bin` is the
separate round-1 table bank for the live Phase 5 wire block primitive.
`phase5_keysched_region_274000.bin` is the 8 KB
static region used by the clean-room Phase 5 key schedule port
(`phase5_key_sched.py` / `Phase5KeySchedule.swift`).
`firstpair_prog_64e2b8_3041b4.bin` and
`firstpair_prog_67cc18_369862.bin` are static program slices used by the
clean-room first-pair source slicer ports. `firstpair_final_len_tables_372102.bin`
contains the paired static lookup tables for the `679f48` length-lane builder.
`firstpair_63c278_u32_tables_112588.bin` and
`firstpair_63c278_fold_tables_2feb18.bin` cover the Swift `63c278` schedule
producer, the adjacent pre-`63c278` affine handoff, the standalone `64cd40`
transform, and the Swift `642f60`/`6473d0` reducer/workspace stages through
the ninth source reducers. The fold window starts at `LIB+0x2feb18` so it also
covers the upstream `6421c0` high-seed helper.
`firstpair_633fa8_tail_fold_tables_2fe798.bin` carries the adjacent
`633fa8` scalar-tail fold banks through `LIB+0x2feb18`, starting with the
tail-qword-to-e10 producer and sized to cover the preceding tail producer too.
`firstpair_633fa8_tail_u32_low_tables_112528.bin` carries the small lower u32
affine window used by the same `633fa8` tail producer before the general
`firstpair_63c278_u32_tables_112588.bin` window starts.
`firstpair_633fa8_null_tables_2fd1f1.bin` and
`firstpair_633fa8_null_nibble_303a14.bin` carry the static windows for the
first null-branch `633fa8` schedule loop and its 4-bit packer.
`firstpair_6388f0_low_seed_statics_2f4d28.bin` is the adjacent three-block
static window consumed by the row-0 low-seed `638840`/`641fcc` recurrence.
`firstpair_6388f0_low_loop_statics_2fe600.bin` carries the small static window
for the low-seed prelude block builder and `6376e4..6379d8` row-0 overwrite
loop.
`firstpair_6388f0_shared_context_2cdae1.bin` and
`firstpair_6388f0_caller_loop_interleaved_2cdfa9.bin` are direct plaintext
`LIB` slices for the repeated `6388f0` caller recurrence: Swift deinterleaves
the latter into the two 59-row loop tables and rebuilds the minimal caller
context used by the Python `streamseed`/`schedseed` model.

The `child23_*` files support the active-sensor recovery kAuth import port
(`child23_kauth_import.py` / `Child23KAuthImport.swift`). The program/code
regions and generated VM tables are static across users and installs.

The tables are fully determined by Abbott's lib; they should not change in
normal development.
