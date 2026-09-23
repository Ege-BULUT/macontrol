# Third-party notices

macontrol adapts code or data only from permissively licensed projects (policy: docs/ARCHITECTURE.md,
section 11). Every adaptation adds an entry here in the same commit, with the upstream project, the commit
it was taken from, the files it went into, and the full license text.

## Homebrew (BSD-2-Clause)

- Upstream: https://github.com/Homebrew/brew @ 3f12c3e
- Used in: `Sources/Safety/ProtectedLocations.swift` (`systemRoots`, `homeRoots`)
- What: the starting lists of system and home folders Homebrew refuses to delete (`SYSTEM_DIRS`, `UNDELETABLE_PATHS` in `Library/Homebrew/cask/macos.rb`). macontrol uses them as protected containment roots.

```
Copyright (c) 2009-present, Homebrew contributors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## PureMac (MIT)

- Upstream: https://github.com/momenbasel/PureMac @ bef6083
- Used in: `Sources/Safety/ProtectedLocations.swift` (cloud provider paths)
- What: the cloud provider state folders from `ProviderPaths.swift`. macontrol protects them from deletion.

```
Copyright (c) 2026 PureMac Contributors

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

<!--
Entry template:

## <Project> (<license>)

- Upstream: <url> @ <commit>
- Used in: <macontrol files>
- What: <what was taken and how it was changed>

<full license text, including the copyright line>
-->
