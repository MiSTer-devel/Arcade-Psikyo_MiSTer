#!/usr/bin/env python3
"""Validate .mra files before deploying them.

WHY
---
On 2026-08-23 an edit to the maincpu comment block left a `-->` in place that
had already closed the comment, so the new prose landed in the document as
character data. It contained `<- u127`, and a bare `<` is illegal in XML, so
MiSTer refused the file: the DIP switches vanished from the OSD, the ROM never
loaded, and the core came up on an all-zero image (SP=PC=00000000, black
screen). That looked exactly like a core regression and cost a debugging round
trip before the user reported the on-screen "XML parse" message.

Nothing about that failure is visible by reading the diff, and MiSTer's own
parser is lenient enough that some malformations load fine while others kill
the file. So check mechanically, every time, before copying an .mra to the
device.

Checks:
  1. The file is well-formed XML (strict -- stricter than MiSTer's parser).
  2. No element carries stray non-whitespace TEXT content. Every leaked
     comment block shows up here, including ones MiSTer currently tolerates.
  3. <switches default="..."> byte count matches the number of declared bits,
     and the file declares a <setname> (the .CFG filename depends on it).
  4. <rotation> matches the set's orientation in MAME's psikyo.cpp GAME()
     line: ROT0 -> "horizontal", ROT270 -> "vertical (ccw)". Taken from
     Brendan Saricks' rotation fix to the three vertical World MRAs
     (aa86c34/9dd5c79/537f99b), which left their alternates as plain
     "vertical"; this keeps every set of a game consistent.

Usage:
    python scripts/validate_mra.py releases/*.mra
Exit status is non-zero if any file fails, so it works as a gate:
    python scripts/validate_mra.py releases/*.mra && <deploy>
"""
import glob
import sys
import xml.etree.ElementTree as ET

# MAME orientation per set (psikyo.cpp GAME() lines), as the .mra rotation tag.
ROTATION = {
    'samuraia': 'vertical (ccw)', 'samuraiak': 'vertical (ccw)',
    'sngkace': 'vertical (ccw)',  'sngkacea': 'vertical (ccw)',
    'gunbird': 'vertical (ccw)',  'gunbirdj': 'vertical (ccw)',  'gunbirdk': 'vertical (ccw)',
    's1945': 'vertical (ccw)',    's1945a': 'vertical (ccw)',    's1945j': 'vertical (ccw)',
    's1945k': 'vertical (ccw)',   's1945n': 'vertical (ccw)',    's1945nj': 'vertical (ccw)',
    'btlkroad': 'horizontal',     'btlkroadk': 'horizontal',
    'tengai': 'horizontal',       'tengaij': 'horizontal',
}

# Elements whose text content is meaningful and must not be flagged.
TEXT_OK = {'part', 'name', 'setname', 'year', 'manufacturer', 'category',
           'rbf', 'rotation', 'players', 'joystick', 'region', 'about',
           'mratimestamp', 'catver', 'mameversion', 'status', 'nvram'}


def check(path):
    problems = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        return ['not well-formed XML: %s' % e]

    root = tree.getroot()
    for el in root.iter():
        if el.tag in TEXT_OK:
            continue
        for blob, where in ((el.text, 'text'), (el.tail, 'tail')):
            if blob and blob.strip():
                snippet = ' '.join(blob.split())[:70]
                problems.append(
                    'stray %s content in <%s>: %r\n'
                    '        (a comment block almost certainly closed early -- '
                    'check for a premature "-->")' % (where, el.tag, snippet))

    if root.find('setname') is None:
        problems.append('no <setname>; the per-core .CFG filename depends on it')
    else:
        setname = (root.findtext('setname') or '').strip()
        rotation = (root.findtext('rotation') or '').strip()
        if setname not in ROTATION:
            problems.append('<setname> %r has no known MAME orientation' % setname)
        elif rotation != ROTATION[setname]:
            problems.append('<rotation> is %r, MAME orientation for %s is %r'
                            % (rotation, setname, ROTATION[setname]))

    sw = root.find('switches')
    if sw is not None and sw.get('default'):
        nbytes = len([x for x in sw.get('default').split(',') if x.strip()])
        bits = []
        for dip in sw.findall('dip'):
            for b in (dip.get('bits') or '').split(','):
                if b.strip().isdigit():
                    bits.append(int(b))
        if bits and max(bits) >= nbytes * 8 + 16:
            problems.append(
                'switches default has %d bytes but a <dip> uses bit %d, which '
                'is outside the range those bytes can cover' % (nbytes, max(bits)))
    return problems


def main(argv):
    files = []
    for pat in (argv or ['releases/*.mra']):
        files.extend(sorted(glob.glob(pat)))
    if not files:
        print('no .mra files matched'); return 1

    bad = 0
    for f in files:
        problems = check(f)
        if problems:
            bad += 1
            print('FAIL  %s' % f)
            for p in problems:
                print('        %s' % p)
        else:
            print('OK    %s' % f)
    if bad:
        print('\n%d of %d file(s) failed -- do NOT deploy these.' % (bad, len(files)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
