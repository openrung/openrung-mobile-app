// LibboxKit is a shell target: its entire payload is the static Libbox
// archive, force-loaded whole via -Wl,-all_load (see project.yml). The
// framework target just needs at least one translation unit to produce a
// binary; nothing here is meant to grow.
