### Fixed
- App updates now actually install silently. Sparkle was quietly rejecting the app's silent-install configuration and routing every update — including the Update button — through its own interactive dialog, which could appear hidden behind other windows. Updating *to* this version still uses the old flow; updates *from* it on are silent.
- If Sparkle ever does need user interaction for an update (e.g. installing would require admin authorization), its dialog now comes to the front instead of hiding behind other windows, and the update completes there.

