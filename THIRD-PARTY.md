# Third-party components

The public Portable and Installer assets obtain the pinned WebKit archive directly from Microsoft's Playwright CDN during setup. The archive SHA-256 is recorded in engine.json. The standalone Installer is built with [Inno Setup 6.7.4](https://github.com/jrsoftware/issrc/releases/tag/is-6_7_4).

- The engine package is the Windows x64 Playwright WebKit artifact (build 2388). Its lock file records the download URL and SHA-256. [Playwright source and patches](https://github.com/microsoft/playwright/tree/v1.65.1/browser_patches/webkit).
- The matching upstream WebKit revision is 5b391e6d3b14d549908dad2c6695999291313f30. WebKit incorporates code under BSD-style and GNU LGPL terms, with file-level terms in the source tree. [Matching WebKit source](https://github.com/WebKit/WebKit/tree/5b391e6d3b14d549908dad2c6695999291313f30).
- The C API headers copied into third_party/WebKit retain their original notices. WebCore LGPL texts are under third_party and copied into the preview. The prebuilt package also contains third-party DLLs such as ICU, libcurl, LibreSSL and image codecs. Their source references are maintained by the [Windows WebKit requirements project](https://github.com/WebKitForWindows/WebKitRequirements). Prepare complete redistribution notices and applicable source obligations before publishing a binary release.
- The browser statically links [Lua 5.4.9](https://www.lua.org/ftp/) under the MIT license. The upstream source is vendored under third_party/Lua, and the license is included in the preview bundle. The official archive SHA-256 is recorded below.
- Reader mode embeds [Mozilla Readability 0.6.0](https://github.com/mozilla/readability/tree/0.6.0) under Apache 2.0. The upstream JavaScript is under third_party/Readability and its license is included in the preview bundle.

~~~text
lua-5.4.9.tar.gz  2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
~~~
