# Third-party notices

This directory vendors the runtime addon and native libraries built from
[`shiena/godot-gsplat`](https://github.com/shiena/godot-gsplat) commit
`dfc8df4893f0f6e26c847590ff1669fa8404da6d`.

`godot-gsplat` is MIT licensed. Its license text is included in `LICENSE`.
The Android library builds the pinned upstream source without source patches.
In particular, its 84-byte sort push constant is kept unchanged so the byte
count matches Godot 4.7 shader reflection on Android. The existing desktop
libraries retain the recorded 12-byte compatibility patch. That patch and the
complete Cargo lockfile are stored under `scripts/third_party`.

The native libraries statically include godot-rust/gdext crates version
`0.5.5`, licensed under MPL-2.0. Those crate sources are not modified. Exact
crate versions and registry checksums are recorded in
`scripts/third_party/godot-gsplat-Cargo.lock`; corresponding source is
available from [godot-rust/gdext](https://github.com/godot-rust/gdext) and
crates.io.

Other transitive Rust dependencies and their exact versions/checksums are also
recorded in the Cargo lockfile. No third-party source is copied into this
repository beyond the upstream addon scripts and the explicitly recorded
desktop compatibility patch.
