"""Compile Pliant with a Regular origin; never rewrite compiled font tables."""

import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import glyphsLib
from fontmake.font_project import FontProject
from fontmake.instantiator import Instantiator
from fontTools.designspaceLib import DesignSpaceDocument, InstanceDescriptor, SourceDescriptor
from fontTools.pens.recordingPen import RecordingPointPen
from fontTools.ttLib import TTFont
from glyphsLib.interpolation import apply_instance_data_to_ufo

BUILD = Path("build")
STYLES = ("Pliant", "Pliant-Italic")


def expand_languages(match):
    """Glyphs' multi-language shorthand is not valid Adobe feature syntax."""
    languages = match[1].split()
    return f"language {languages[0]};\n{match[2]}" + "".join(
        f"\nlanguage {language};\nlookup {match[3]};" for language in languages[1:]
    )


def build(style):
    font = glyphsLib.GSFont(f"sources/{style}.glyphs")
    for tag in ("liga", "dlig"):
        del font.features[tag]
    font.features["locl"].code = re.sub(
        r"language ([A-Z ]+);\n(lookup (\w+) \{.*?\} \3;)",
        expand_languages,
        font.features["locl"].code,
        flags=re.DOTALL,
    )
    doc = glyphsLib.to_designspace(font)
    directory = BUILD / style
    directory.mkdir(parents=True)
    for index, source in enumerate(doc.sources):
        source.filename = f"master-{index}.ufo"
        source.font.save(directory / source.filename)
    doc.write(directory / "original.designspace")

    # Axis mappings are significant: user weight 400 maps to source weight 90.
    regular = next(
        instance
        for instance in doc.instances
        if instance.styleName == ("Italic" if style.endswith("Italic") else "Regular")
    )
    interpolator = Instantiator.from_designspace(doc, round_geometry=False)
    width = next(axis for axis in doc.axes if axis.tag == "wdth")
    # Include the entire Regular width row, not just the new default corner.
    for index, value in enumerate((width.minimum, width.maximum)):
        instance = copy.deepcopy(regular)
        instance.location[width.name] = width.map_forward(value)
        if value != width.default:
            instance.styleName = "Expanded " + regular.styleName
        master = interpolator.generate_instance(instance)
        apply_instance_data_to_ufo(master, instance, doc)
        source = SourceDescriptor()
        source.name = f"{style}-regular-{index}"
        source.familyName = instance.familyName
        source.styleName = instance.styleName
        source.location = instance.location
        source.font = master
        source.filename = f"regular-{index}.ufo"
        master.save(directory / source.filename)
        doc.addSource(source)

    next(axis for axis in doc.axes if axis.tag == "wght").default = 400
    for source in doc.sources:
        is_default = source.location == regular.location
        source.copyInfo = source.copyLib = source.copyFeatures = is_default
    doc.write(directory / f"{style}.designspace")
    FontProject().run_from_designspace(
        str(directory / f"{style}.designspace"),
        output=("variable",),
        output_dir=str(BUILD / "fonts"),
    )
    FontProject().run_from_designspace(
        str(directory / f"{style}.designspace"),
        output=("ttf",),
        interpolate=True,
        output_dir=str(BUILD / "static"),
    )


def assert_close(left, right):
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        assert abs(left - right) < 1e-6, (left, right)
    elif isinstance(left, (tuple, list)):
        assert len(left) == len(right)
        for a, b in zip(left, right, strict=True):
            assert_close(a, b)
    elif isinstance(left, dict):
        assert left.keys() == right.keys()
        for key in left:
            assert_close(left[key], right[key])
    else:
        assert left == right, (left, right)


def check_interpolation(style):
    """Verify every glyph's source geometry across the weight/width space."""
    original, regular = (
        DesignSpaceDocument.fromfile(BUILD / style / f"{name}.designspace")
        for name in ("original", style)
    )
    before = Instantiator.from_designspace(original, round_geometry=False)
    after = Instantiator.from_designspace(regular, round_geometry=False)
    for weight in (100, 250, 400, 550, 900):
        for width in (100, 112.5, 125):
            instance = InstanceDescriptor()
            instance.styleName = "Interpolation check"
            instance.location = {
                axis.name: axis.map_forward({"wght": weight, "wdth": width}[axis.tag])
                for axis in original.axes
            }
            a = before.generate_instance(instance)
            b = after.generate_instance(instance)
            assert set(a.keys()) == set(b.keys())
            assert a.groups == b.groups
            for pair in a.kerning.keys() | b.kerning.keys():
                assert_close(a.kerning.get(pair, 0), b.kerning.get(pair, 0))
            for name in sorted(a.keys()):
                try:
                    assert_close(a[name].width, b[name].width)
                    pens = RecordingPointPen(), RecordingPointPen()
                    a[name].drawPoints(pens[0])
                    b[name].drawPoints(pens[1])
                    # Smooth flags and editor identifiers are not geometry;
                    # Instantiator may copy them from a different base master.
                    outlines = [
                        [
                            (op, args[:2] if op == "addPoint" else args)
                            for op, args, _kwargs in pen.value
                        ]
                        for pen in pens
                    ]
                    assert_close(*outlines)
                except AssertionError as error:
                    raise AssertionError((style, weight, width, name)) from error


def check_font(path, *, variable):
    font = TTFont(path)
    italic = "Italic" in path.name
    assert bool(font["OS/2"].fsSelection & 1) == italic
    if variable:
        assert {
            axis.axisTag: (axis.minValue, axis.defaultValue, axis.maxValue)
            for axis in font["fvar"].axes
        } == {"wght": (100, 400, 900), "wdth": (100, 100, 125)}
        assert font["OS/2"].usWeightClass == 400
        assert font["name"].getDebugName(1) == "Pliant"
        assert font["name"].getDebugName(2) == ("Italic" if italic else "Regular")
        assert {i.coordinates["wght"] for i in font["fvar"].instances} == set(
            range(100, 1000, 100)
        )
    else:
        assert "fvar" not in font and "gvar" not in font
        assert font["OS/2"].usWidthClass == 5
        family = font["name"].getDebugName(16) or font["name"].getDebugName(1)
        assert family == "Pliant"
        weight_names = (
            "Thin",
            "ExtraLight",
            "Light",
            "Regular",
            "Medium",
            "SemiBold",
            "Bold",
            "ExtraBold",
            "Black",
        )
        weight = next(
            index * 100
            for index, name in enumerate(weight_names, start=1)
            if path.stem
            == (
                "Pliant-Italic"
                if italic and name == "Regular"
                else f"Pliant-{name}{'Italic' if italic else ''}"
            )
        )
        assert font["OS/2"].usWeightClass == weight
    features = {f.FeatureTag for f in font["GSUB"].table.FeatureList.FeatureRecord}
    assert not features.intersection({"liga", "clig", "dlig"})
    assert {"ccmp", "locl"} <= features
    assert "GPOS" in font
    for text in ("fi", "fl", "ft", "tt"):
        shaped = json.loads(
            subprocess.check_output(
                [
                    "hb-shape",
                    str(path),
                    text,
                    "--features=liga=1,clig=1,dlig=1",
                    "--output-format=json",
                ],
                text=True,
            )
        )
        assert len(shaped) == 2, (path, text, shaped)


if __name__ == "__main__":
    if sys.argv[1:] == ["build"]:
        for style in STYLES:
            build(style)
    elif sys.argv[1:] == ["check"]:
        for style in STYLES:
            check_interpolation(style)
        fonts = sorted((BUILD / "fonts").glob("*.ttf"))
        assert len(fonts) == 2, fonts
        for path in fonts:
            check_font(path, variable=True)
        statics = sorted((BUILD / "static").glob("*.ttf"))
        assert len(statics) == 18, statics
        for path in statics:
            check_font(path, variable=False)
        assert {
            (TTFont(path)["OS/2"].usWeightClass, "Italic" in path.name) for path in statics
        } == {(weight, italic) for weight in range(100, 1000, 100) for italic in (False, True)}
    else:
        sys.exit("usage: build.py build|check")
