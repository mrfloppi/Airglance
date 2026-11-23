# Third-party notices

This project's own code is MIT licensed (see `LICENSE`). The Mac app bundles a Python environment
with the following open-source packages (installed from `requirements.txt` and their dependencies).
Their licenses apply to those packages; full license texts are included in each package's
`*.dist-info` folder inside `AirGlance.app/Contents/Resources/venv/lib/python3.15/site-packages/`.

| Package | Version | License |
|---|---|---|
| aiofiles | 25.1.0 | Apache-2.0 |
| aiohappyeyeballs | 2.7.1 | PSF-2.0 |
| aiohttp | 3.14.5 | Apache-2.0 AND MIT |
| aiosignal | 1.4.0 | Apache 2.0 |
| AlexaPy | 1.37.1 | Apache-2.0 |
| annotated-doc | 0.0.7 | MIT |
| annotated-types | 0.8.0 | MIT |
| anyio | 4.16.0 | MIT |
| attrs | 26.1.0 | MIT |
| authcaptureproxy | 1.3.9 | Apache-2.0 |
| backoff | 2.2.1 | MIT |
| beautifulsoup4 | 4.15.0 | MIT License |
| certifi | 2026.11.20 | MPL-2.0 |
| cffi | 2.1.1 | MIT-0 |
| charset-normalizer | 3.5.3 | MIT |
| cryptography | 50.0.2 | Apache-2.0 OR BSD-3-Clause |
| frozenlist | 1.8.0 | Apache-2.0 |
| h11 | 0.16.0 | MIT |
| h2 | 4.4.1 | MIT |
| hpack | 4.2.0 | MIT |
| httpcore | 1.0.9 | BSD-3-Clause |
| httpx | 0.28.1 | BSD-3-Clause |
| hyperframe | 6.1.0 | MIT License |
| idna | 3.20 | BSD-3-Clause |
| markdown-it-py | 4.3.0 | MIT License |
| mdurl | 0.1.2 | MIT License |
| multidict | 6.9.1 | Apache License 2.0 |
| propcache | 0.5.4 | Apache-2.0 |
| pycparser | 3.12 | BSD-3-Clause |
| pydantic | 2.14.4 | MIT |
| pydantic_core | 2.50.5 | MIT |
| Pygments | 2.21.0 | BSD-2-Clause |
| PyOTP | 2.12.1 | MIT |
| requests | 2.34.2 | Apache-2.0 |
| rich | 15.0.0 | MIT |
| shellingham | 1.5.4 | ISC License |
| simplejson | 4.3.0 | MIT OR AFL-2.1 |
| soupsieve | 4.1.3 | MIT |
| typer | 0.29.2 | MIT |
| typing-inspection | 0.4.5 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.8.0 | MIT |
| yarl | 1.25.1 | Apache-2.0 |

Notes:
- `certifi` (MPL-2.0) is redistributed unmodified.
- The app bundles the Python runtime **CPython 3.15.2** (PSF License, text in
  `Contents/Resources/python/lib/python3.15/LICENSE.txt`) as built by
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone). That build links further
  open-source libraries (e.g. OpenSSL – Apache-2.0, SQLite – public domain, libffi – MIT, zlib, xz, bzip2,
  mpdecimal, expat); see the project's licensing notes for the complete list.
- Inspired by and built on [alexapy](https://gitlab.com/keatontaylor/alexapy) and the Home Assistant integration
  [alexa_media_player](https://github.com/alandtse/alexa_media_player).
