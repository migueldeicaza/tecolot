# Website

GitHub Pages serves this site at `https://tecolot.com/`. It is published by
`.github/workflows/pages.yml`, not from a branch: the repository is configured
with a `workflow` build type, so a `CNAME` file is neither used nor needed. The
custom domain lives in the repository Pages settings.

`public/` holds the complete site and is uploaded without a build step.
`index.html` is an interactive Design Canvas document. It uses `support.js` for
the client-side component runtime and `assets/owl.png` for the site artwork.
The runtime loads pinned React and Babel releases from unpkg. The site also
loads Archivo and JetBrains Mono from Google Fonts.

Serve this directory through HTTP for local development. Do not open
`index.html` through a `file:` URL:

```sh
python3 -m http.server 8000 --directory website/public
```

The site reads the current public version from `appcast.xml`. If the feed is not
available, the interface shows `LATEST` and still links to the stable GitHub
Releases URL.

## public/appcast.xml

The Sparkle update feed. **Its URL is load-bearing.** Every copy of Tecolot that
people have installed reads `https://tecolot.com/appcast.xml`, the value of
`SUFeedURL` in `Tecolot/Info.plist`, and there is no way to tell an installed
copy about a new address. Never move or rename this file.

`.github/workflows/release.yml` adds an entry to it through
`scripts/update-appcast.py` on each release, then asks this workflow to publish
it. Do not edit it by hand.

Because the feed ships with the site, a website build that fails also stops
update delivery. `pages.yml` checks that the feed is present and well formed
before it deploys, so a broken deploy leaves the previous feed in place rather
than replacing it with a broken one.
