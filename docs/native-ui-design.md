# Native interface: prototype implementation

Branch: `codex/native-ui-design`. Baseline: `26c8fef` on `master` commits the one-window and in-place packaging work before the redesign.

## Reference and approach

The reference is the supplied `jottie-frontend` workspace at `http://localhost:3002/`, specifically `components/meetings/`, `app/globals.css` and its synthetic meeting fixtures. The two supplied screenshots show the same desktop workspace in summary and transcript states. The React source supplies layout and behaviour examples; no React, browser runtime or Electron dependency is introduced into Jottie.

Native views use the existing repository and knowledge services. Colours, radii, spacing, typography and interaction styling live in `Sources/JottieUI/DesignSystem.swift`. The prototype's Geist family and Geist Mono are bundled with their OFL notice and pinned source revision. SwiftUI buttons, text inputs, document tabs, pills, cards, empty states and tag popovers provide the corresponding components. Subtle hover/press transitions use native animation. Three independently scrollable panes use custom SwiftUI dividers, initially targeting a 248-point sidebar and 360-point list. Dividers support dragging, double-click reset and keyboard/accessibility adjustment; widths remain stable across Settings/Queue navigation. The window has a 1040 × 640 minimum size.

## Screen mapping

| Prototype | Native implementation | Real behaviour |
| --- | --- | --- |
| `meeting-workspace.tsx` | `LibraryWindow.swift` | One manager, breadcrumb, update/import/record actions and recording status |
| `library-sidebar.tsx` | `LibraryWindow.swift` | All meetings, durable Starred, Queue, recoverable Trash, nested folders, collapse, drag/drop, theme and Settings |
| `meeting-list.tsx` | `MeetingListPane.swift` | Date groups, summary cards, snippets, search, tag/date filtering, ascending/descending sort and pagination |
| `meeting-detail.tsx` | `MeetingDetailPane.swift` | Summary, timestamped full transcript, editable speakers, copy, stars, regeneration and evidence links |
| `folder-summary.tsx` | `FolderDetailPane.swift` | Real summary-only subtree context, freshness, updates, findings and source meetings |
| `queue-view.tsx` | `QueuePane.swift` | Actual outstanding analysis/context/publication jobs, progress, errors and retries |
| `settings-view.tsx` | `LibraryEditors.swift` | Full-page prompt settings plus native Codex, capture, calendar, Microsoft and MCP controls |

A regular click selects one meeting; Command-click toggles items and Shift-click extends from the focused meeting. Arrow keys move through the list and Command-A selects the loaded results. Dragging a selected meeting files the selection together. Context menus retain batch export, regeneration, moving and local Trash; multiple selection also reveals export/Trash in the list footer. Pagination remains explicit rather than loading an unbounded library. Folder context opens when selecting the folder; choosing a meeting replaces that context in the reading pane.

The toolbar's Update summaries action explicitly regenerates summaries made with earlier prompt/model settings, resumes missing analysis and refreshes folder context. Saving settings preserves old meeting revisions. It does not silently regenerate completed meetings. Stars and manual speaker names/job titles are canonical meeting metadata, with optional fields so older records remain readable. AI re-analysis and repeated imports retain those manual values.

## Deliberate differences and limits

- Import lives in the header. All meetings includes unfiled records; the sidebar now also includes a separate recoverable Trash collection.
- Design-preview badges, sample-only status and simulated processing are omitted from the real app. Counts, dates, durations, sources and freshness reflect actual records. Transcript durations appear only when segment timestamps provide them; text-only imports do not invent durations.
- The prototype's action checkboxes are represented by evidence-derived status indicators. They are not personal task-completion controls. Updating an action's completion manually would need a separate provenance contract so a click cannot be misrepresented as transcript evidence. This is a product/data-model difference, not a SwiftUI styling limitation.
- The Queue displays real outstanding work and the current work-set progress. It does not display the prototype's fabricated completed-job history.
- macOS window controls/title-bar space, file pickers, permission prompts and Microsoft authentication retain their native presentation. Capture settings are now custom components within the main window; OS-controlled permission dialogs remain outside application styling.
- SF Symbols substitute for Lucide glyphs except the supplied Import paths; some strokes and silhouettes differ. The tag selector uses a custom SwiftUI list inside a native popover, so popover chrome and keyboard focus rendering differ from the browser. Other model/calendar/date pickers keep native accessibility and platform behaviour.
- Text rasterisation, scrollbar visibility and menu animation depend on macOS. Matching CSS pixels cannot guarantee identical screenshots across display scales or accessibility settings. Desktop resizing is supported; the prototype's mobile/sidebar drawer flow is not a macOS pilot requirement.
- Speaker job titles can be entered manually. The subsequent BambooHR integration adds calendar-invite directory matches separately, preserving the distinction between an invitee and a confirmed speaker.

None of these observations requires Electron to reproduce the primary desktop layout. A shared React runtime would become relevant if using the exact same web components and DOM behaviours across platforms becomes a requirement. That is a separate stack decision; capture, calendar, permissions, authentication and packaging would still need native adapters.

## Verification

Development uses the prototype's synthetic fixture in `Tests/JottieTests/Fixtures/design-library.json`; no real meeting is submitted to a provider for UI QA. The opt-in `exportNativeDesignFixture` test writes an isolated library to `JOTTIE_DESIGN_LIBRARY`. Open it with `jottie library --library <path>` to inspect real native views without starting capture or processing. Do not substitute the user's library path for fixture generation.

Automated coverage includes starred search across pagination and index rebuilds, sort order, durable speaker metadata, unchanged source transcripts, unknown-channel rejection, multi-selection/navigation, font availability and reusing one window after closing/reopening. Capture/recovery and existing library/knowledge/MCP/publication tests remain the regression gate. Interactive visual checks and their outcomes are recorded after the build is packaged.

### Completed checks — 27 October 2026

- Final `swift test --no-parallel`: 767 inherited tests and 38 Jottie tests passed; the older optional preview was skipped. This run included the isolated fixture exporter and native design renderer. The Python suite passed all 30 tests with two optional skips.
- The final native render is `.build/qa/native-design-summary.png`, using only synthetic prototype meetings. It confirms the three-pane proportions, selected cards, light palette, bundled Geist typography and compact document tabs.
- The committed arm64 application passed code-signature verification, packaged executable loading and the macOS 14.2 compatibility gate. `make app` replaced the canonical `.build/Jottie.app`; test fixture bundles are excluded from the app.
- In the packaged application, Computer Use verified the 248-point sidebar and 360-point list, accessibility resizing to 264 points and persistence when returning from Settings, summary/transcript/speaker tabs, tag filtering, saving a synthetic speaker role, and evidence-popover links opening the cited transcript segment. Keyboard tag selection works by tabbing into the popover, moving with arrows, and pressing Return; Escape dismisses it.
- UI QA used `jottie library --library /tmp/jottie-native-design-20261027`. No microphone capture or provider generation was invoked during those checks. Microsoft sign-in/publication and real recording permissions were not retested by this design pass. Synthetic preview windows do not save the normal app's frame or theme preferences.

The next native UI pass adds Trash, the supplied inward-arrow Import icon, connected folder-tree branches and consolidated settings. See [directory, Trash and settings](bamboohr-and-trash.md) for behaviour and validation boundaries.
