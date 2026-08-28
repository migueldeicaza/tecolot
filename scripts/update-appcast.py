#!/usr/bin/env python3
"""Insert a release into the Sparkle appcast that tecolot.com serves.

The release workflow calls this after it has signed the update archive. Running
it twice for the same build replaces the existing entry instead of adding a
duplicate, so a re-run of a failed release is safe.
"""

import argparse
import datetime
import email.utils
import pathlib
import xml.etree.ElementTree as ElementTree

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

EMPTY_APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{namespace}">
  <channel>
    <title>Tecolot</title>
    <link>https://tecolot.com/appcast.xml</link>
    <description>Updates for Tecolot, a native terminal for macOS.</description>
    <language>en</language>
  </channel>
</rss>
""".format(namespace=SPARKLE_NAMESPACE)


def sparkle(name):
    return f"{{{SPARKLE_NAMESPACE}}}{name}"


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True,
                        help="Marketing version, such as 0.0.15.")
    parser.add_argument("--build", required=True,
                        help="CFBundleVersion. Sparkle compares this, not --version.")
    parser.add_argument("--url", required=True, help="Download URL of the archive.")
    parser.add_argument("--length", required=True, help="Size of the archive in bytes.")
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update.")
    parser.add_argument("--minimum-system-version", required=True,
                        help="Three part version, such as 15.5.0.")
    parser.add_argument("--release-notes-link", required=True)
    return parser.parse_args()


def build_item(arguments):
    item = ElementTree.Element("item")
    ElementTree.SubElement(item, "title").text = arguments.version
    # Sparkle parses pubDate as "E, dd MMM yyyy HH:mm:ss Z", so the zone has to
    # be numeric. formatdate(usegmt=True) writes "GMT", which that pattern rejects.
    ElementTree.SubElement(item, "pubDate").text = email.utils.format_datetime(
        datetime.datetime.now(datetime.timezone.utc))
    ElementTree.SubElement(item, sparkle("version")).text = arguments.build
    ElementTree.SubElement(item, sparkle("shortVersionString")).text = arguments.version
    ElementTree.SubElement(item, sparkle("minimumSystemVersion")).text = \
        arguments.minimum_system_version
    ElementTree.SubElement(item, sparkle("releaseNotesLink")).text = arguments.release_notes_link
    ElementTree.SubElement(item, "enclosure", {
        "url": arguments.url,
        "length": arguments.length,
        "type": "application/octet-stream",
        sparkle("edSignature"): arguments.signature,
    })
    return item


def main():
    arguments = parse_arguments()
    ElementTree.register_namespace("sparkle", SPARKLE_NAMESPACE)

    if not arguments.appcast.exists():
        arguments.appcast.parent.mkdir(parents=True, exist_ok=True)
        arguments.appcast.write_text(EMPTY_APPCAST)

    tree = ElementTree.parse(arguments.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit(f"error: {arguments.appcast} has no <channel> element.")

    # Drop any earlier entry for this build so a repeated run stays idempotent.
    for existing in channel.findall("item"):
        version = existing.find(sparkle("version"))
        if version is not None and version.text == arguments.build:
            channel.remove(existing)

    # Newest first, ahead of every existing item but after the channel metadata.
    # Sparkle does not require the order; it keeps the diff readable and puts
    # the current release at the top of the file.
    children = list(channel)
    insert_at = len(children)
    for index, child in enumerate(children):
        if child.tag == "item":
            insert_at = index
            break
    channel.insert(insert_at, build_item(arguments))

    ElementTree.indent(tree, space="  ")
    tree.write(arguments.appcast, encoding="utf-8", xml_declaration=True)
    arguments.appcast.write_text(arguments.appcast.read_text().rstrip("\n") + "\n")
    print(f"Added Tecolot {arguments.version} (build {arguments.build}) to {arguments.appcast}.")


if __name__ == "__main__":
    main()
