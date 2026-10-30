#!/usr/bin/env python3
"""Writes the LV2 metadata for both Tapestry plugins: <name>.ttl (ports), presets.ttl and
manifest.ttl, from one table, so the mono and stereo bundles never drift apart.

    python3 tools/gen_ttl.py            # both bundles
    python3 tools/gen_ttl.py mono       # or just one: mono | stereo

The TTL must match the code: tools/check (the playbook's check.sh) compares it with DPF's
generator. Versions here and TAPESTRY_VERSION / d_version() in the code move together."""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PLUGINS = {
    'mono': dict(
        bundle='nhe-tapestry', uri='urn:mod-cookbook:nhe-tapestry', name='Tapestry', micro=9,
        comment="Tape machines from studio reel to answering machine: wow, flutter, saturation and tape's low end.",
        audio=[('in', 'In', 'in'), ('out', 'Out', 'out')]),
    'stereo': dict(
        bundle='nhe-tapestry-stereo', uri='urn:mod-cookbook:nhe-tapestry-stereo', name='Tapestry Stereo', micro=1,
        comment="Stereo tape machines from studio reel to answering machine: two tracks on one transport, wow, flutter, saturation and tape's low end.",
        audio=[('in_l', 'In L', 'in'), ('in_r', 'In R', 'in'), ('out_l', 'Out L', 'out'), ('out_r', 'Out R', 'out')]),
}

FORMATS = ["Studio reel", "Home reel", "Walkman", "VHS", "Pocket", "Answering", "Master", "8-track", "4-track"]
TAPES = ["Cheap", "Ferric", "Chrome", "Metal"]


def enum(labels):
    pts = ' ,\n'.join('            [ rdfs:label "%s" ; rdf:value %d ]' % (l, i) for i, l in enumerate(labels))
    return " ;\n        lv2:portProperty lv2:integer , lv2:enumeration ;\n        lv2:scalePoint\n" + pts


# symbol, name, default, min, max, extra
CONTROLS = [
    ('format', 'Format', 2, 0, len(FORMATS) - 1, enum(FORMATS)),
    ('tape', 'Tape', 1, 0, len(TAPES) - 1, enum(TAPES)),
    ('drive', 'Drive', 0, -12, 18, ' ;\n        units:unit units:db'),
    ('tone', 'Tone', 0, -5, 5, ''),
    ('wow', 'Wow', 100, 0, 200, ' ;\n        units:unit units:pc'),
    ('flutter', 'Flutter', 100, 0, 200, ' ;\n        units:unit units:pc'),
    ('age', 'Age', 3, 0, 10, ''),
    ('hiss', 'Noise', 0, 0, 10, ''),        # symbol kept from 1.0.x so saved presets still load
    ('mix', 'Mix', 100, 0, 100, ' ;\n        units:unit units:pc'),
    ('level', 'Level', 0, -12, 12, ' ;\n        units:unit units:db'),
    ('lv2_enabled', 'Enabled', 1, 0, 1, ' ;\n        lv2:portProperty lv2:integer , lv2:toggled ;\n        lv2:designation lv2:enabled'),
]

# key, label, format, tape, drive, tone, wow, flutter, age, noise
PRESETS = [
    ('always-on', 'Always on', 6, 1, 6, 0, 100, 100, 0, 0),
    ('walkman-cheap', 'Walkman, cheap tape', 2, 0, 3, 0, 110, 100, 5, 1),
    ('walkman-chrome', 'Walkman, chrome', 2, 2, 0, 0, 100, 100, 2, 1),
    ('studio-half-inch', 'Studio half-inch', 0, 1, 4, 0, 100, 100, 1, 1),
    ('home-reel', 'Home reel-to-reel', 1, 1, 2, 0, 100, 100, 3, 1),
    ('pocket-dictaphone', 'Pocket dictaphone', 4, 1, 0, 0, 100, 100, 4, 1),
    ('answering-machine', 'Answering machine', 5, 0, 0, 0, 120, 100, 6, 1),
    ('vhs-linear', 'VHS linear', 3, 1, 0, 0, 100, 100, 3, 1),
    ('eight-track', '8-track cartridge', 7, 1, 2, 0, 100, 100, 5, 1),
    ('bedroom-four-track', 'Bedroom 4-track', 8, 2, 4, 0, 100, 100, 2, 1),
]


def write(which):
    P = PLUGINS[which]
    U = P['uri']
    out = os.path.join(ROOT, 'bundle', P['bundle'] + '.lv2')
    ttl = """@prefix doap:   <http://usefulinc.com/ns/doap#> .
@prefix foaf:   <http://xmlns.com/foaf/0.1/> .
@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .
@prefix rdf:    <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:   <http://www.w3.org/2000/01/rdf-schema#> .
@prefix units:  <http://lv2plug.in/ns/extensions/units#> .

<%s>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    doap:name "%s" ;
    doap:license <http://spdx.org/licenses/GPL-3.0-or-later.html> ;
    doap:maintainer [ foaf:name "New Horizon" ] ;
    rdfs:comment "%s" ;
    lv2:minorVersion 2 ;
    lv2:microVersion %d ;
    lv2:optionalFeature lv2:hardRTCapable ;
    lv2:requiredFeature <http://lv2plug.in/ns/ext/options#options> ,
                        <http://lv2plug.in/ns/ext/urid#map> ;
    lv2:extensionData <http://lv2plug.in/ns/ext/options#interface> ;
    lv2:port """ % (U, P['name'], P['comment'], P['micro'])
    blocks = []
    for i, (sym, name, kind) in enumerate(P['audio']):
        blocks.append("""[
        a lv2:%s , lv2:AudioPort ;
        lv2:index %d ;
        lv2:symbol "%s" ;
        lv2:name "%s"
""" % ('InputPort' if kind == 'in' else 'OutputPort', i, sym, name))
    n0 = len(P['audio'])
    for i, (sym, name, d, mn, mx, extra) in enumerate(CONTROLS):
        blocks.append("""[
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index %d ;
        lv2:symbol "%s" ;
        lv2:name "%s" ;
        lv2:default %s ;
        lv2:minimum %s ;
        lv2:maximum %s%s
""" % (n0 + i, sym, name, d, mn, mx, extra))
    ttl += '    ] , '.join(blocks) + "    ] .\n"
    open(os.path.join(out, P['bundle'] + '.ttl'), 'w').write(ttl)

    pre = """@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
"""
    man = """@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<%s>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    lv2:binary <%s_dsp.so> ;
    rdfs:seeAlso <%s.ttl> , <modgui.ttl> .
""" % (U, P['bundle'], P['bundle'])
    for key, label, fm, tp, dr, to, wo, fl, ag, nz in PRESETS:
        # No Mix: presets set the machine, not the balance, so loading one leaves your Mix where it is
        vals = dict(format=fm, tape=tp, drive=dr, tone=to, wow=wo, flutter=fl, age=ag, hiss=nz, level=0)
        ports = ' ,\n'.join('        [ lv2:symbol "%s" ; pset:value %s ]' % (k, float(v)) for k, v in vals.items())
        pre += """
<%s#%s>
    a pset:Preset ;
    lv2:appliesTo <%s> ;
    rdfs:label "%s" ;
    lv2:port
%s .
""" % (U, key, U, label, ports)
        man += """
<%s#%s>
    a pset:Preset ;
    lv2:appliesTo <%s> ;
    rdfs:label "%s" ;
    rdfs:seeAlso <presets.ttl> .
""" % (U, key, U, label)
    open(os.path.join(out, 'presets.ttl'), 'w').write(pre)
    open(os.path.join(out, 'manifest.ttl'), 'w').write(man)
    print('wrote', os.path.relpath(out, ROOT), '(version 2.%d)' % P['micro'])


if __name__ == '__main__':
    for w in (sys.argv[1:] or ['mono', 'stereo']):
        write(w)
