# Third-party notices

Jottie includes the following open-source components. Exact copies of their
license texts are included in every application bundle under
`Contents/Resources/Licenses`.

| Component | Version | License |
|---|---:|---|
| [LocalVQE](https://github.com/localai-org/LocalVQE) (echo canceller) | f53063c | Apache License 2.0 |
| [ggml](https://github.com/ggml-org/ggml), distributed with LocalVQE | c044a8e | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache License 2.0 |
| fastcluster, distributed with FluidAudio | bundled | BSD 2-Clause |
| vbx, distributed with FluidAudio | bundled | Apache License 2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache License 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | MIT and bundled external notices |
| Ed25519 verification code distributed with Sparkle | bundled | zlib-style license |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 1.9.4 / b5130 (927cfce) | MIT |
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | 0.2.0 | MIT |
| ggml, distributed with transcribe.cpp | bundled | MIT |
| miniz, distributed with transcribe.cpp | bundled | MIT |

Amanu itself is available under the [MIT license](LICENSE), retaining the
copyright and license notice of the quill project from which it began.

The LocalVQE build uses a small Amanu macOS packaging patch to produce one
self-contained Intel dylib instead of runtime-loaded CPU-variant libraries.
The inference implementation and model are otherwise the pinned upstream work.

## Jottie additions

| Component | Version | Licence |
|---|---:|---|
| GRDB.swift | 7.11.1 | MIT |
| Model Context Protocol Swift SDK | 0.12.1 | MIT |
| Microsoft Authentication Library (MSAL) | 2.16.0 | MIT |
| swift-log | 1.16.2 | Apache 2.0 with Runtime Library Exception |
| swift-system | 1.8.1 | Apache 2.0 with Runtime Library Exception |
| EventSource | 1.5.1 | MIT |
| swift-collections | 1.7.4 | Apache 2.0 with Runtime Library Exception |
| swift-atomics | 1.3.1 | Apache 2.0 with Runtime Library Exception |
| swift-nio | 2.104.0 | Apache 2.0 with Runtime Library Exception |

Exact licence texts for these dependencies are included in Resources/Licenses and copied into the application bundle. The upstream Amanu and Quill copyright notices remain intact.

## Native interface typography

[Geist and Geist Mono](https://github.com/vercel/geist-font) are bundled unmodified
under the SIL Open Font License 1.1. Copyright 2024 The Geist Project Authors.
The font files, exact source revision and full OFL notice are in the JottieUI
resource bundle under `Fonts/` (`SOURCE.txt` and `OFL.txt`).

## Lucide Import icon

The user-supplied Lucide Import icon is rendered as native SwiftUI paths in `DesignSystem.swift`. Other interface icons use SF Symbols.

ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
