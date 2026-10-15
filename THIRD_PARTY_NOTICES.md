# Third-party notices

## Coucou

Parts of the coding-agent tracking (the `jc-hook` relay, the agent engine, the
approval arbiter, the hook installers), the Jarvis Mac app (notch island, Flow
dictation, wake word, note-taker, local chat, music and mail) and the services
pollers follow the design of Coucou, github.com/Louis-CFM/coucou. Files that do
say so in a comment ("after coucou … MIT").

Only Coucou's source code is MIT-licensed. Its name ("Coucou"), the Mochi
character, its icons, sounds and media belong to Louis Raillé and are not used
here; Jarvis has its own names, orb and sounds.

```
MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Simple Icons — agent logos (iPhone Live Activities)

The agent logos in `ios_app/JarvisWidget/AgentLogos.xcassets` (shown on each
coding agent's Live Activity and in its settings row) are unmodified SVGs from
[Simple Icons](https://simpleicons.org), released under CC0 1.0 Universal:

| Asset | Simple Icons slug | Package |
|---|---|---|
| `agent_claude` | `claude` | `simple-icons@16.33.0` (npm, sha256 of the tarball `11e1ab7c…2d2375`) |
| `agent_gemini` | `googlegemini` | `simple-icons@16.33.0` |
| `agent_copilot` | `githubcopilot` | `simple-icons@16.33.0` |
| `agent_cursor` | `cursor` | `simple-icons@16.33.0` |
| `agent_opencode` | `opencode` | `simple-icons@16.33.0` |
| `agent_openai` | `openai` | `simple-icons@15.22.0` (sha256 `ed6c09b0…1de89`; the icon left Simple Icons in 16.0.0) |

Simple Icons' own data marks the GitHub Copilot icon as MIT: it comes from
GitHub's Primer Octicons (`@primer/octicons`), whose license reads:

```
MIT License

Copyright (c) 2025 GitHub Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Agents Simple Icons doesn't carry use SF Symbols instead: Amp (`bolt.fill` —
Simple Icons' `amp` is the AMP web framework, not Sourcegraph's agent),
Antigravity (`atom`) and Muse (`sparkles`). Jarvis keeps its own orb.

The logos are trademarks of their owners (Anthropic, OpenAI, Google, GitHub,
Anysphere, the OpenCode project). CC0 covers the drawings only — no trademark
rights are granted — and they are used here only to say which agent a session
belongs to.
