#import <Foundation/Foundation.h>

// MediaRemote "Now Playing" adapter, vendored from nowplaying-cli (BSD-3,
// Jonas van den Berg). internal_get() performs one synchronous (<=2s) read of
// the macOS Now Playing bus and returns the normalized dict (title, artist,
// album, playing, processIdentifier, elapsedTime, duration, artworkData,
// artworkMimeType) or nil when nothing is playing. macOS only — the sidecar's
// now-playing PROVIDER SEAM has OS-specific implementations (Linux MPRIS,
// Windows SMTC); see orbit-sidecar.swift.
extern NSDictionary * _Nullable internal_get(BOOL isTestMode);
