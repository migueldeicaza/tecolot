#!/usr/bin/env python3
"""Check that a site directory carries the Sparkle feed the app asks for.

Every installed copy of Tecolot reads the feed from the URL baked into its
Info.plist, and there is no way to tell an installed copy about a different
address. Publishing a site without the feed at that exact path would stop all
updates, so the website workflow runs this first and refuses to deploy.
"""

import argparse
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ElementTree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publish_directory", type=pathlib.Path)
    parser.add_argument("--info-plist", type=pathlib.Path,
                        default=pathlib.Path("Tecolot/Info.plist"))
    arguments = parser.parse_args()

    info = plistlib.loads(arguments.info_plist.read_bytes())
    feed_url = info.get("SUFeedURL")
    if not feed_url:
        sys.exit(f"error: {arguments.info_plist} has no SUFeedURL.")

    feed_file = arguments.publish_directory / feed_url.rsplit("/", 1)[-1]
    if not feed_file.is_file():
        sys.exit(f"error: Info.plist points at {feed_url}, "
                 f"but {feed_file} does not exist.")

    try:
        ElementTree.parse(feed_file)
    except ElementTree.ParseError as error:
        sys.exit(f"error: {feed_file} is not well formed XML: {error}")

    print(f"{feed_url} will be served from {feed_file}.")


if __name__ == "__main__":
    main()
