# Chunksee Sample World

An original, fictional 256-by-256-block island made for Chunksee. It includes a cabin,
a chest with twelve diamonds, two named pets, one sample player and a zombie spawner.
It is demonstration data for this read-only viewer, not a complete Minecraft gameplay save.
All player and animal identities are synthetic. No user world, Mojang artwork or other
third-party world is included.

The sample is newly authored project content. No separate license or distribution
permission is introduced by this feature.
`ChunkseeTests/SampleWorldFixture.swift` is the content recipe. It uses the existing
TestWorld fixture writers and ChunkseeKit's public NBT/compression APIs. Bundled sample
files are always read in place; Chunksee never edits them.
