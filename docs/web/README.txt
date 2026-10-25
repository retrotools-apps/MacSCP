MacSCP static website

The source website uses the project's current version, changelog and native
demonstration screenshots. No real sessions or desktop captures are used.

Regenerate documents and check local links:
  python3 scripts/prepare-website
  python3 scripts/prepare-website --check
  python3 -m unittest discover -s scripts/tests -p test_website.py

Preview on loopback:
  python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/web

Export for deployment:
  python3 scripts/prepare-website --output /new/empty/directory

GitHub Pages uses .github/workflows/pages.yml to export and deploy this site.
In Settings > Pages, select GitHub Actions as the publishing source.
The export excludes this readme, system metadata and unreviewed assets.
The local commands above do not publish anything.
