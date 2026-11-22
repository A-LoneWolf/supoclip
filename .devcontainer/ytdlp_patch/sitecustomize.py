# Auto-loaded by Python at startup (the folder is on PYTHONPATH inside the
# backend/worker containers). SupoClip uses yt-dlp as a Python library, which
# ignores config files, so this adds a cookie file to every YoutubeDL() instance.
# Harmless if YTDLP_COOKIEFILE is unset or yt-dlp is not installed.

import os

try:
    import yt_dlp

    _orig_init = yt_dlp.YoutubeDL.__init__

    def _patched_init(self, params=None, auto_init=True):
        params = dict(params or {})
        cookie_file = os.environ.get("YTDLP_COOKIEFILE")
        if cookie_file and os.path.exists(cookie_file):
            params.setdefault("cookiefile", cookie_file)
        return _orig_init(self, params, auto_init)

    yt_dlp.YoutubeDL.__init__ = _patched_init
except Exception:
    pass
