# Third-party notices

This directory vendors the runtime addon and native libraries built from
[`shiena/godot-gsplat`](https://github.com/shiena/godot-gsplat) commit
`dfc8df4893f0f6e26c847590ff1669fa8404da6d`.

`godot-gsplat` is MIT licensed. Its license text is included in `LICENSE`.
Scene Sync applies the recorded 12-byte push-constant padding patch to two
MIT-licensed upstream source files before building. The patch and the complete
Cargo lockfile are stored under `scripts/third_party`.

The native libraries statically include godot-rust/gdext crates version
`0.5.5`, licensed under MPL-2.0. Those crate sources are not modified. Exact
crate versions and registry checksums are recorded in
`scripts/third_party/godot-gsplat-Cargo.lock`; corresponding source is
available from [godot-rust/gdext](https://github.com/godot-rust/gdext) and
crates.io.

Other transitive Rust dependencies and their exact versions/checksums are also
recorded in the Cargo lockfile. No third-party source is copied into this
repository beyond the upstream addon scripts and the explicitly recorded
compatibility patch.
