# PhotoRenamer

A native macOS SwiftUI app that connects to a Piwigo photo server and uses AI (Claude API) and Apple Vision face recognition to generate descriptive titles for photos.

## Build & Run

```bash
swift build
.build/debug/PhotoRenamer &
```

Requires Xcode (for macOS SDK). Built with Swift Package Manager — no `.xcodeproj` needed.

Note: `/usr/local/include/Block.h` from Homebrew's xz/lzma package conflicts with Apple's SDK. If the build fails with a `Block.h` error, rename it: `sudo mv /usr/local/include/Block.h /usr/local/include/Block.h.bak`

The app runs as a raw executable (not a `.app` bundle). It calls `NSApplication.shared.setActivationPolicy(.regular)` at startup to appear in the Dock and app switcher.

## Architecture

```
Package.swift              # Swift Package Manager config, macOS 14+
Sources/
  PhotoRenamerApp.swift    # App entry point, owns PiwigoClient and FaceManager
  SettingsView.swift       # Connection screen: Piwigo URL/credentials, Claude API key
  AlbumBrowserView.swift   # 3-panel NavigationSplitView: album tree | photo grid | detail
  PhotoDetailView.swift    # Single photo view: preview, face detection, AI naming, rename
  BatchRenameView.swift    # Batch rename workflow: scan → face review → AI naming → review → apply
  PiwigoClient.swift       # Piwigo REST API client (login, albums, images, rename)
  ClaudeClient.swift       # Anthropic API client (image description, multi-image with references)
  FaceManager.swift        # Apple Vision face detection, feature print matching, face database
  FaceLabelView.swift      # Face labeling UI components, known faces management panel
```

## Key Design Decisions

### Piwigo Integration
- Communicates via Piwigo's REST API (`ws.php?format=json`)
- Albums are fetched with `pwg.categories.getList&recursive=true` and built into a tree using `id_uppercat` parent references
- The `id_uppercat` field comes as a string from some Piwigo versions — parsing handles both string and int
- Renames update the Piwigo **title** (`pwg.images.setInfo` with `name` param), not the filename — filenames are left unchanged for safety
- Image derivatives parsed: square, thumb, medium, large, xlarge, xxlarge. Largest available is used for face detection; medium for display

### Face Recognition
- Uses Apple Vision framework — no Python or external dependencies
- `VNDetectFaceRectanglesRequest` for face detection
- `VNGenerateImageFeaturePrintRequest` on cropped face regions for generating comparable embeddings
- Match threshold: 1.5 (feature print distance). Lower = stricter
- Ambiguity detection: if top two matches for different people are within 30% distance (or 0.15 absolute), the match is flagged as uncertain
- Face samples are filtered by date: only samples within +-10 years of the target photo are considered, to account for appearance changes over time
- Face database persisted at `~/Library/Application Support/PhotoRenamer/known_faces.json` with crop images in `face_crops/`

### Photo Date Extraction (priority order)
1. EXIF `DateTimeOriginal` from image data (via `CGImageSource`)
2. Year parsed from album path (regex for 4-digit years 1900-2099)
3. Piwigo's `date_creation` field

### AI Naming
- Single photo: sends image + identified people names + album path to Claude API
- Batch mode: sends reference photos of identified people alongside each photo, so Claude can recognize people by clothing/hair/body even without a clear face
- Naming style: `YYYYMMDD NNN Description` (e.g., "20251112 001 Sarah and John on a boat")
- Date prefix and sequence number are added client-side; Claude generates only the descriptive title
- Uses `claude-sonnet-4-20250514` model

### Batch Rename Workflow
1. **Scan**: downloads all photos, runs face detection, matches against known faces
2. **Face review**: interactive grid — tap unknown faces to label them, builds reference photos for each identified person (picks the photo with the largest face crop)
3. **Generate**: sends each photo to Claude with reference photos and context
4. **Review**: editable table of old title → new title with checkboxes, apply selected

## Settings Storage
- Piwigo URL, username, Claude API key stored via `@AppStorage` (UserDefaults)
- Piwigo password is not persisted (entered each session)
- Face database is in Application Support (see above)
