# Website

GitHub Pages serves this site at `https://tecolot.com/`. It is published by
`.github/workflows/pages.yml`, not from a branch: the repository is configured
with a `workflow` build type, so a `CNAME` file is neither used nor needed. The
custom domain lives in the repository Pages settings.

`public/` holds files that are copied to the site root without change. Astro,
which `PLAN.md` proposes for the real site, uses the same convention, so these
files keep their URLs when the site gets built for real. At that point,
`pages.yml` gains a build step and uploads `website/dist` instead of
`website/public`.

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
