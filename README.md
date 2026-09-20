# APPEARANCE.R4X

`APPEARANCE.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.14`
- Image target: `/R4OS/SOFTWARE/DESKTOP/APPEARANCE.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

COLOR_V1 now declares revision 4, matching its current generated binding;
older minimum 2 was rejected before the color settings could open.

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

`/DISPLAY` opens display settings, also available from the Desktop Settings
menu. It uses the common output catalog and asynchronous atomic mode API,
initializes an SDR test-pattern buffer and releases its creator reference
after submission. The common owner keeps accepted references and the 15-second
confirmation timer. Keep, Revert, Escape and window close follow that same
transaction; completion requires driver receipts. Only progressive RGB8 modes
on one active switchable output are offered. Bootfb displays a fixed-mode
explanation. Settings apply for the current session; physical NVIDIA image
acceptance remains in `ExFiles/Reports/OssiGPU.txt`.

The existing model test step covers source ownership, rejected requests,
confirmation and close during a pending change using a modeled ABI transport.
Display settings uses bounded buffered Canvas commands and the full client
dimensions; the main Appearance window also has no fixed maximum size.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


Appearance: Konfiguration ab 0.78.63
---------------------------------
Vor einer Aenderung von DESKTOP.R4S wird R4STD-Recovery abgeschlossen und
der wiederhergestellte Inhalt gelesen. Lese-/Groessenfehler verhindern das
Speichern. Die vier Appearance-Werte werden gemeinsam komponiert; andere
Schluessel wie TASKBAR_CLOCK und UI_FONT bleiben erhalten. Publikation
verwendet weiterhin R4STD CONFIG_V1 saveDocument.

Graphics startup (0.79.42)
-------------------------
APPEARANCE /DISPLAY -> Graphics driver shows the confirmed output owner,
loaded R4D version, declared firmware bundle, current boot policy and fallback
reason. Unknown versions stay unknown; a bundle label never proves GPU
firmware execution. Color and VRR remain separate per-output settings.

Save startup edits C:\CONFIG.R4S for the next boot using checked atomic
replacement. Unrelated lines/comments remain intact; Automatic also replaces
an existing NVIDIA mode override with auto. Software overrides native options
before GPU access. Oversized/unreadable config and concurrent changes fail
closed; an ambiguous write retains its temporary copies. The boot-menu
Software Graphics entry applies once and leaves this file unchanged.
