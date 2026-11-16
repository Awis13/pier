# Notices

Pier is licensed under the Mozilla Public License 2.0 (LICENSE). It includes or
builds on:

- **crate** (https://github.com/oneamendez/crate), MPL-2.0: the VM engine, used
  from a fork with a vsock device (https://github.com/Awis13/crate, branch
  `containers`).
- **crate-ios** (https://github.com/oneamendez/crate-ios), MPL-2.0:
  `ios/Sources/Pier/JIT/` and `ios/Sources/JITHelper/` come from it; each file
  keeps its licence header. They turn on JIT through a built-in StikJIT helper
  (StikJIT, MPL-2.0).
- **apple/containerization** (https://github.com/apple/containerization),
  Apache-2.0: used from a fork with a crate backend
  (https://github.com/Awis13/containerization, branch `crate`). Pier's guest
  agent (`vminitd`, `vmexec`) is built from that fork.
- **SwiftTerm** (https://github.com/migueldeicaza/SwiftTerm), MIT.
- **Yams** (https://github.com/jpsim/Yams), MIT.
- **Mozilla CA certificate bundle** (`Sources/PierCore/Resources/cacert.pem`,
  via https://curl.se/docs/caextract.html), MPL-2.0.
- **Nerd Fonts** (https://github.com/ryanoasis/nerd-fonts), each font under its
  own licence, kept in `ios/Resources/Fonts/licenses`.
- **iTerm2-Color-Schemes** (https://github.com/mbadolato/iTerm2-Color-Schemes),
  MIT: `ios/Resources/themes.json` (see `themes-LICENSE.txt`).
- **Linux** (GPL-2.0): the guest kernel, built from kernel.org sources with
  `guest/kernel.config` (Kata Containers' arm64 config plus Landlock).
