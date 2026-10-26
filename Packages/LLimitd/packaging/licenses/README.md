# Bundled license texts

`packaging/build-deb.sh` packages a fully static `llimit` built with the Swift
static Linux SDK, which links the libraries below into the binary. Their
notices ship in the `.deb` under `/usr/share/doc/llimit/`:

- `Third-Party-Notices.txt`, written by `scripts/swiftpm-notices.py` from
  `notices.json`. It fails when the installed SDK's `sbom.spdx.json` lists a
  package or version that `notices.json` does not cover.
- `copyright` (DEP-5), written by `scripts/deb-copyright.py` from
  `components.json`.

`scripts/static-runtime-notices.py` then compares both files with what the
stripped binary links. The Swift license text is read from the toolchain at
build time; the SDK ships no license texts, so they are kept here.

| File | Upstream | SHA-256 |
| --- | --- | --- |
| `ICU-74.1-LICENSE.txt` | unicode-org/icu `LICENSE` at `release-74-1` (ICU in `swift-foundation-icu` for Swift 6.0 to 6.2) | `17510cf7a58b4879b887ec05a45d72cf1b73544dd9ec7e72f20110ed104229ee` |
| `curl-8.7.1-COPYING.txt` | curl `COPYING` at `curl-8_7_1` | `adb1fc06547fd136244179809f7b7c2d2ae6c4534f160aa513af9b6a12866a32` |
| `boringssl-fips-20220613-LICENSE.txt` | BoringSSL `LICENSE` at `fips-20220613` | `60bd7c54856bf9387221bde5ab55d516d7cea15870d0fed69406bcd1c8ec7c9d` |
| `zlib-1.3.1-LICENSE.txt` | madler/zlib `LICENSE` at `v1.3.1` | `845efc77857d485d91fb3e0b884aaa929368c717ae8186b66fe1ed2495753243` |
| `musl-1.2.5-COPYRIGHT.txt` | musl `COPYRIGHT` at `v1.2.5` | `f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af` |
| `musl-fts-1.2.7-COPYING.txt` | void-linux/musl-fts `COPYING` at `v1.2.7` | `55af87e4017668f54467a3380e7ebbac5e672d8c763bfe95e6fc882a6fdc4046` |

These match `swift-6.2.3-RELEASE_static-linux-0.0.1`. When the Swift release
or SDK changes, fetch the texts at the versions its SBOM lists (Swift 6.3 and
6.4 use ICU 76.1) and update `notices.json` and `components.json` together.
