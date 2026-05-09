#!/usr/bin/env python3
"""Simple movie download server — browse and download MP4s to your phone.
Runs on port 8080. Access via Tailscale: http://100.74.35.117:8080
"""
import os, http.server, urllib.parse, json

MOVIES_DIR = "/Volumes/M4Drive/media/movies"
TV_DIR = "/Volumes/M4Drive/media/tvshows"
PORT = 8080

HTML_TEMPLATE = """<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Media Downloads</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, sans-serif; background: #111; color: #eee; padding: 20px; }
h1 { font-size: 24px; margin-bottom: 20px; }
h2 { font-size: 18px; color: #888; margin: 20px 0 10px; }
.movie { display: flex; justify-content: space-between; align-items: center;
         background: #222; padding: 15px; margin: 8px 0; border-radius: 8px; }
.movie .title { font-size: 16px; }
.movie .size { color: #888; font-size: 14px; }
.movie a { background: #1db954; color: #fff; padding: 10px 20px; border-radius: 20px;
           text-decoration: none; font-weight: bold; font-size: 14px; white-space: nowrap; }
.movie a:active { background: #1aa34a; }
</style></head><body>
<h1>Media Downloads</h1>
<p style="color:#888;margin-bottom:20px;">Tap Download, save to your phone, play with VLC.</p>
{content}
</body></html>"""

def human_size(nbytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if nbytes < 1024: return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"

def scan_media(base_dir, category):
    items = []
    if not os.path.isdir(base_dir):
        return items
    for folder in sorted(os.listdir(base_dir)):
        folder_path = os.path.join(base_dir, folder)
        if not os.path.isdir(folder_path) or folder.startswith('.'):
            continue
        for f in os.listdir(folder_path):
            if f.startswith('.') or f.startswith('._'):
                continue
            if f.endswith(('.mp4', '.mkv', '.m4v')):
                fpath = os.path.join(folder_path, f)
                size = os.path.getsize(fpath)
                items.append({'name': folder, 'file': f, 'path': fpath, 'size': size, 'category': category})
    return items

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/download':
            params = urllib.parse.parse_qs(parsed.query)
            fpath = params.get('file', [''])[0]
            if os.path.isfile(fpath) and '/media/' in fpath:
                self.send_response(200)
                fname = os.path.basename(fpath)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', f'attachment; filename="{fname}"')
                self.send_header('Content-Length', str(os.path.getsize(fpath)))
                self.end_headers()
                with open(fpath, 'rb') as f:
                    while chunk := f.read(1024 * 1024):
                        self.wfile.write(chunk)
            else:
                self.send_error(404)
        else:
            movies = scan_media(MOVIES_DIR, 'Movies')
            tv = scan_media(TV_DIR, 'TV Shows')
            content = ""
            if movies:
                content += "<h2>Movies</h2>"
                for m in movies:
                    dl_url = f"/download?file={urllib.parse.quote(m['path'])}"
                    content += f'<div class="movie"><div><div class="title">{m["name"]}</div><div class="size">{human_size(m["size"])}</div></div><a href="{dl_url}">Download</a></div>'
            if tv:
                content += "<h2>TV Shows</h2>"
                for t in tv:
                    dl_url = f"/download?file={urllib.parse.quote(t['path'])}"
                    content += f'<div class="movie"><div><div class="title">{t["name"]} — {t["file"]}</div><div class="size">{human_size(t["size"])}</div></div><a href="{dl_url}">Download</a></div>'
            if not content:
                content = "<p>No media found.</p>"
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.replace('{content}', content).encode())

    def log_message(self, format, *args): pass

if __name__ == '__main__':
    print(f"Download server running on http://0.0.0.0:{PORT}")
    http.server.HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
