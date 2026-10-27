# Custom Jottie interface: feasibility and scope

Status: the first native implementation now follows the supplied React prototype on `codex/native-ui-design`. See [Native interface implementation](native-ui-design.md) for component mappings, verification and remaining differences. The estimates below describe the original scope assessment.

## Recommendation

Keep the current Swift/SwiftUI stack for the macOS pilot. A supplied design with the visual character of shadcn/ui can be implemented in SwiftUI: custom colours, typography, spacing, borders, radii, inputs, buttons, tabs, badges, menus, tables and panels. A new application stack is not required to achieve that appearance.

The component source would be native SwiftUI. React components, Tailwind classes and shadcn/ui source cannot be dropped directly into the current views. Treat those as design references and implement equivalent native components. Apple explicitly supports custom button appearance through [ButtonStyle](https://developer.apple.com/documentation/swiftui/buttonstyle) and custom control composition in [SwiftUI controls](https://developer.apple.com/documentation/swiftui/controls-and-indicators). An [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable) wrapper can supply AppKit behaviour where SwiftUI does not expose enough control.

## What the existing code lets us keep

The meeting manager is in `Sources/JottieUI`, hosted in an AppKit window. `LibraryViewModel` connects the views to persistence, analysis, folders and publishing. Its services and portable JSON contracts do not depend on the visual styles. A redesign can replace the presentation while retaining those operations, the capture engine and the MCP service.

The older recording/permission settings and first-run wizard are AppKit views in `Sources/amanu/UI`. Their native layout would need a separate design pass or migration into the same SwiftUI component library. Operating-system permission dialogs, authentication windows and file pickers retain their platform-controlled appearance.

The current `List`, `Form`, `TabView`, toolbar and `NavigationSplitView` deliberately use system styling. A fully custom design will involve replacing some of their containers and interaction wiring, rather than applying one theme modifier. Large meeting lists still need efficient scrolling, stable selection, keyboard navigation, drag-and-drop and accessible focus. Custom text inputs must retain selection, IME composition, undo, copy/paste and VoiceOver support; native text editing underneath a custom border is usually the best starting point.

## Proposed implementation sequence

| Work | Indicative effort for one experienced SwiftUI developer |
| --- | --- |
| Audit supplied screens, states, resizing rules and component inventory | 0.5–1 day |
| Implement tokens and roughly 8–12 reusable controls with interaction states | 2–4 days |
| Apply them to the three-pane manager, details and current settings/editors | 5–8 days |
| Validate keyboard/accessibility, drag/drop, large lists, window sizing and light/dark appearances | 2–4 days |

Allow roughly 2–4 working weeks for that scope. This is a planning estimate grounded in the current view structure, not a quotation. Detailed designs, the number of distinct screens, animations and advanced rich-text requirements could change it. Backend features, Windows UI, a component catalogue application and a custom rich-text editor are outside this estimate.

Before implementation, provide the screens plus typography/assets, spacing/colour tokens, minimum window sizes and hover/focus/disabled/loading/error/empty states. Agree one representative screen first, then build the reusable controls and apply them across the manager. A screenshot alone does not specify all the interactions.

## When another stack would be justified

A web frontend becomes worth considering if sharing the same React component source across macOS, Windows and a browser becomes a product requirement, or if existing shadcn/Tailwind implementation code must run unchanged. That is a broader architecture decision: it adds a native bridge for capture, permissions, files, calendar and authentication, changes packaging, and requires its own performance/accessibility validation. Switching solely to obtain custom styling would add unnecessary work to this pilot.

For Windows later, the portable models and service contracts remain useful either way. SwiftUI macOS views do not become a Windows interface automatically. Choose the Windows presentation stack after the macOS workflow and final design are established, as required by the pilot plan.
